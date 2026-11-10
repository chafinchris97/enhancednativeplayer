import CoreGraphics
import Foundation
import ImageIO
import Logging
import UniformTypeIdentifiers

/// The I-frame rendition built from trickplay sprite sheets: `iframe.m3u8` has one entry per
/// second of the playlist timeline, and `iframe_{n}.mp4` is the thumbnail showing at that second,
/// cut out of its sheet and served as a Motion JPEG fragment. A thumbnail standing for 10 s is
/// therefore served 10 times, each time stamped at its own second.
///
/// Sheets are fetched when a thumbnail in them is first asked for. A sheet is decoded once and all
/// of its thumbnails encoded as JPEG together; those stay in memory for the session (a few MB).
final class TrickplayRendition: Sendable {
    /// A JPEG over this is encoded again at a lower quality, so the master's BANDWIDTH holds.
    static let maxStillBytes = 64 * 1024
    static let qualities: [CGFloat] = [0.8, 0.6, 0.4]

    let trickplay: Trickplay
    let index: TrickplayIndex
    let initSegment: Data
    /// Seconds of the playlist timeline, as the media playlists add up.
    let duration: Double
    /// Where the playlist timeline starts in the file's timeline, in seconds.
    let originSeconds: Double
    /// The media playlists' clock: the `tfdt` of the playlist timeline's start, in `MotionJPEGFragments.timescale`.
    let startTime: UInt64
    private let tiles: TrickplayTileStore

    /// Nil, logged, when `trickplay` doesn't add up: playback goes ahead without thumbnails.
    init?(_ trickplay: Trickplay, duration: Double, originSeconds: Double, headers: [String: String], logger: Logger) {
        if let problem = trickplay.problem {
            logger.warning("Trickplay left out: \(problem)")
            return nil
        }
        let index = TrickplayIndex(trickplay: trickplay, count: trickplay.thumbnailCount(fileSeconds: originSeconds + duration))
        self.trickplay = trickplay
        self.index = index
        self.duration = duration
        self.originSeconds = originSeconds
        self.startTime = UInt64(Timeline.leadInMicroseconds / 1000)
        self.initSegment = MotionJPEGFragments.initSegment(width: trickplay.width, height: trickplay.height)
        self.tiles = TrickplayTileStore(index: index, headers: headers, logger: logger)
        logger.info("Trickplay: \(index.count) thumbnails of \(trickplay.width)x\(trickplay.height) every \(trickplay.interval) ms in \(trickplay.sheets.count) sheets of \(trickplay.tileWidth)x\(trickplay.tileHeight)")
    }

    /// One entry per second; the last one takes what is left.
    var entryCount: Int {
        max(1, Int((duration - 0.000_5).rounded(.up)))
    }

    func entryDuration(_ index: Int) -> Double {
        min(1, duration - Double(index))
    }

    /// The highest bit rate one entry can reach: the largest still, plus its boxes, in a second.
    var bandwidth: Int {
        (Self.maxStillBytes + 512) * 8
    }

    /// One thumbnail a second, each the size the sheets average one at: their bit rate over the
    /// file times the seconds a thumbnail stands for.
    var averageBandwidth: Int {
        let perThumbnail = Double(trickplay.bandwidth) * Double(trickplay.interval) / 1000
        return min(bandwidth, max(1, Int(perThumbnail.rounded(.up))))
    }

    /// `iframe_{index}.mp4`
    func fragment(_ index: Int) async throws -> Data {
        let (sheet, tile) = self.index.thumbnail(atFileSeconds: Double(index) + originSeconds)
        guard (0..<entryCount).contains(index) else { throw EnhancedPlayerError.segmentOutOfRange(index) }
        let jpeg = try await tiles.jpeg(sheet: sheet, tile: tile)
        let timescale = Double(MotionJPEGFragments.timescale)
        let start = startTime + UInt64(index) * UInt64(timescale)
        let duration = UInt32(max(1, (entryDuration(index) * timescale).rounded()))
        return MotionJPEGFragments.fragment(jpeg: jpeg, sequence: UInt32(index + 1), start: start, duration: duration)
    }
}

/// Every thumbnail of a sheet as its own JPEG, by sheet, fetched and cut on first use.
actor TrickplayTileStore {
    private let index: TrickplayIndex
    private let headers: [String: String]
    private let logger: Logger
    private var sheets: [Int: [Data]] = [:]
    private var loading: [Int: Task<[Data], Error>] = [:]

    init(index: TrickplayIndex, headers: [String: String], logger: Logger) {
        self.index = index
        self.headers = headers
        self.logger = logger
    }

    func jpeg(sheet: Int, tile: Int) async throws -> Data {
        let stills = try await stills(of: sheet)
        return stills[min(tile, stills.count - 1)]
    }

    private func stills(of sheet: Int) async throws -> [Data] {
        if let stills = sheets[sheet] { return stills }
        if let task = loading[sheet] { return try await task.value }
        let trickplay = index.trickplay
        let url = trickplay.sheets[sheet]
        let layout = SheetLayout(columns: trickplay.tileWidth, count: index.count(ofSheet: sheet), width: trickplay.width, height: trickplay.height)
        let headers = headers
        let logger = logger
        let task = Task {
            let started = ContinuousClock.now
            let data = try await Self.fetch(url, headers: headers)
            let stills = try await runBlocking(label: "ENP.trickplay") {
                try Self.cut(data, layout: layout)
            }
            logger.info("Trickplay sheet \(sheet): \(stills.count) thumbnails, \(stills.reduce(0) { $0 + $1.count } / 1024) KB, in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])))")
            return stills
        }
        loading[sheet] = task
        defer { loading[sheet] = nil }
        let stills = try await task.value
        sheets[sheet] = stills
        return stills
    }

    /// Where a sheet's thumbnails are.
    struct SheetLayout: Sendable {
        var columns: Int
        /// Thumbnails in this sheet.
        var count: Int
        /// One thumbnail's size in pixels.
        var width: Int
        var height: Int
    }

    enum CutError: Error {
        case undecodable
        case noThumbnailInSheet(width: Int, height: Int)
        case unencodable
    }

    /// Decodes a sheet and encodes each of its thumbnails, row by row, as a JPEG of its own. A last
    /// sheet cut down to the rows it fills ends at its last whole thumbnail.
    static func cut(_ data: Data, layout: SheetLayout) throws -> [Data] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw CutError.undecodable }
        var stills: [Data] = []
        for tile in 0..<layout.count {
            let rect = CGRect(x: tile % layout.columns * layout.width, y: tile / layout.columns * layout.height, width: layout.width, height: layout.height)
            guard rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height), let still = image.cropping(to: rect) else { break }
            stills.append(try encode(still))
        }
        guard !stills.isEmpty else { throw CutError.noThumbnailInSheet(width: image.width, height: image.height) }
        return stills
    }

    private static func encode(_ image: CGImage) throws -> Data {
        var smallest: Data?
        for quality in TrickplayRendition.qualities {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw CutError.unencodable }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CutError.unencodable }
            smallest = out as Data
            if out.length <= TrickplayRendition.maxStillBytes { break }
        }
        return smallest!
    }

    private static func fetch(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EnhancedPlayerError.http(status: http.statusCode, url: url)
        }
        return data
    }
}
