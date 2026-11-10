import CoreGraphics
import Foundation
import ImageIO
import Logging
import Testing
import UniformTypeIdentifiers
@testable import EnhancedNativePlayer

struct TrickplayTests {
    /// A 6400 s file at 320 px: 7 sheets, the last one 40 thumbnails.
    static func sample(sheets: [URL]? = nil) -> Trickplay {
        Trickplay(
            width: 320, height: 180, tileWidth: 10, tileHeight: 10, interval: 10_000, bandwidth: 13_849,
            sheets: sheets ?? (0..<7).map { URL(string: "http://server/Trickplay/320/\($0).jpg")! }
        )
    }

    static func index(_ trickplay: Trickplay, fileSeconds: Double) -> TrickplayIndex {
        TrickplayIndex(trickplay: trickplay, count: trickplay.thumbnailCount(fileSeconds: fileSeconds))
    }

    @Test func countsThumbnailsFromTheSheetsAndTheLength() {
        let trickplay = Self.sample()
        #expect(trickplay.problem == nil)
        let index = Self.index(trickplay, fileSeconds: 6400)
        #expect(index.count == 640)
        #expect((0..<7).map(index.count(ofSheet:)) == [100, 100, 100, 100, 100, 100, 40])
        // A thumbnail starts in the file's last fraction of an interval.
        #expect(trickplay.thumbnailCount(fileSeconds: 6395.5) == 640)
        // The sheets cap it: 6 sheets for a 6016 s film hold 600, ending at 6000 s.
        var shorter = trickplay
        shorter.sheets.removeLast()
        #expect(shorter.thumbnailCount(fileSeconds: 6016.352) == 600)
        #expect(trickplay.thumbnailCount(fileSeconds: 0) == 1)
    }

    @Test func mapsTimesToThumbnails() {
        let index = Self.index(Self.sample(), fileSeconds: 6400)
        func at(_ seconds: Double) -> [Int] {
            let (sheet, tile) = index.thumbnail(atFileSeconds: seconds)
            return [sheet, tile]
        }
        #expect(at(0) == [0, 0])
        #expect(at(9.99) == [0, 0])
        #expect(at(10) == [0, 1])
        #expect(at(999) == [0, 99])
        #expect(at(1000) == [1, 0])
        #expect(at(3000) == [3, 0])
        #expect(at(6395) == [6, 39])
        // Past the last thumbnail, and before the first.
        #expect(at(9000) == [6, 39])
        #expect(at(-3) == [0, 0])
    }

    @Test func followsOtherLayouts() {
        // 480 px thumbnails, 6 across and 4 down, every 2.5 s, for a 124 s file.
        let trickplay = Trickplay(width: 480, height: 270, tileWidth: 6, tileHeight: 4, interval: 2500, bandwidth: 0, sheets: (0..<3).map { URL(string: "http://s/\($0).jpg")! })
        #expect(trickplay.problem == nil)
        let index = Self.index(trickplay, fileSeconds: 124)
        #expect(index.count == 50)
        #expect((0..<3).map(index.count(ofSheet:)) == [24, 24, 2])
        let (sheet, tile) = index.thumbnail(atFileSeconds: 62.5)
        #expect(sheet == 1 && tile == 1)
    }

    @Test func refusesDescriptionsThatDontAddUp() {
        var trickplay = Self.sample()
        trickplay.sheets = []
        #expect(trickplay.problem != nil)
        trickplay = Self.sample()
        trickplay.interval = 0
        #expect(trickplay.problem != nil)
        trickplay = Self.sample()
        trickplay.tileWidth = 0
        #expect(trickplay.problem != nil)
        #expect(TrickplayRendition(trickplay, duration: 100, originSeconds: 0, headers: [:], logger: Logger(label: "test")) == nil)
    }

    // MARK: Boxes

    @Test func initHasOneMotionJPEGTrack() throws {
        let data = MotionJPEGFragments.initSegment(width: 320, height: 180)
        #expect(Boxes.children(of: data).map(\.type) == ["ftyp", "moov"])
        let entry = try #require(Boxes.find(["moov", "trak", "mdia", "minf", "stbl", "stsd"], in: data))
        // stsd: version/flags, entry_count, then the sample entry.
        #expect(Boxes.u32(entry, 4) == 1)
        #expect(String(decoding: entry[entry.startIndex + 12..<entry.startIndex + 16], as: UTF8.self) == "mjpg")
        let sample = entry.dropFirst(16)
        #expect(Boxes.u16(sample, 24) == 320)
        #expect(Boxes.u16(sample, 26) == 180)
        #expect(Boxes.find(["moov", "mvex", "trex"], in: data) != nil)
    }

    @Test func fragmentCarriesTheJPEGAtItsTime() throws {
        let jpeg = Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9])
        let data = MotionJPEGFragments.fragment(jpeg: jpeg, sequence: 8, start: 17_000, duration: 1000)
        let top = Boxes.children(of: data)
        #expect(top.map(\.type) == ["moof", "mdat"])
        let tfdt = try #require(Boxes.find(["moof", "traf", "tfdt"], in: data))
        #expect(Boxes.u64(tfdt, 4) == 17_000)
        let trun = try #require(Boxes.find(["moof", "traf", "trun"], in: data))
        #expect(Boxes.u32(trun, 4) == 1) // sample_count
        let offset = Int(Boxes.u32(trun, 8))
        #expect(Boxes.u32(trun, 12) == 1000)
        #expect(Boxes.u32(trun, 16) == UInt32(jpeg.count))
        // default-base-is-moof: the offset counts from the moof's first byte.
        #expect(data[data.startIndex + offset..<data.startIndex + offset + jpeg.count] == jpeg)
    }

    // MARK: Sheets

    @Test func cutsEachThumbnailOutOfItsSheet() throws {
        // A 3x2 sheet of 4x2 thumbnails, five of them used, each filled with its own grey.
        let layout = TrickplayTileStore.SheetLayout(columns: 3, count: 5, width: 4, height: 2)
        let context = try #require(CGContext(data: nil, width: 12, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        for tile in 0..<6 {
            context.setFillColor(gray: CGFloat(tile) / 5, alpha: 1)
            // Core Graphics draws bottom-up: row 0 is the top 2 pixels.
            context.fill(CGRect(x: tile % 3 * 4, y: 2 - tile / 3 * 2, width: 4, height: 2))
        }
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let stills = try TrickplayTileStore.cut(out as Data, layout: layout)
        #expect(stills.count == 5)
        // A layout asking for more than the sheet holds ends at its last whole thumbnail.
        let beyond = try TrickplayTileStore.cut(out as Data, layout: .init(columns: 3, count: 9, width: 4, height: 2))
        #expect(beyond.count == 6)
        for (tile, still) in stills.enumerated() {
            let image = try #require(CGImageSourceCreateWithData(still as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect(image.width == 4 && image.height == 2)
            let level = Self.meanGray(image)
            #expect(abs(level - Double(tile) / 5) < 0.08, "tile \(tile): \(level)")
        }
    }

    private static func meanGray(_ image: CGImage) -> Double {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) / 255
    }

    // MARK: Rendition

    @Test func iFramePlaylistHasOneEntryASecond() throws {
        let rendition = try #require(TrickplayRendition(Self.sample(), duration: 3.5, originSeconds: 0, headers: [:], logger: Logger(label: "test")))
        #expect(rendition.entryCount == 4)
        #expect(rendition.entryDuration(0) == 1)
        #expect(rendition.entryDuration(3) == 0.5)
        #expect(rendition.startTime == 10_000)
        // 13 849 bit/s over the sheets, one 10 s thumbnail a second.
        #expect(rendition.averageBandwidth == 138_490)
    }

    /// Against a real server: set `ENP_TRICKPLAY_SHEET` to a 320 px 10x10 sheet URL with `{n}` where
    /// the sheet number goes; `ENP_TRICKPLAY_SHEETS` and `ENP_TRICKPLAY_SECONDS` default to the
    /// example above (7 sheets, 6400 s). Writes `init_iframe.mp4` plus some `iframe_{n}.mp4` to
    /// `ENP_TRICKPLAY_OUT`, if set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENP_TRICKPLAY_SHEET"] != nil))
    func servesStillsFromARealServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        let template = environment["ENP_TRICKPLAY_SHEET"]!
        let sheetCount = environment["ENP_TRICKPLAY_SHEETS"].flatMap { Int($0) } ?? 7
        let seconds = environment["ENP_TRICKPLAY_SECONDS"].flatMap { Double($0) } ?? 6400
        let sheets = try (0..<sheetCount).map { try #require(URL(string: template.replacingOccurrences(of: "{n}", with: String($0)))) }
        let rendition = try #require(TrickplayRendition(Self.sample(sheets: sheets), duration: seconds, originSeconds: 0, headers: [:], logger: Logger(label: "test")))
        var files: [(String, Data)] = [("init_iframe.mp4", rendition.initSegment)]
        for index in [0, 1, 9, 10, 11, 60, 3000, Int(seconds) - 1] {
            let fragment = try await rendition.fragment(index)
            #expect(Boxes.children(of: fragment).map(\.type) == ["moof", "mdat"])
            files.append(("iframe_\(index).mp4", fragment))
        }
        if let out = environment["ENP_TRICKPLAY_OUT"] {
            let directory = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        }
    }
}

/// Just enough ISO BMFF reading to check the boxes written.
enum Boxes {
    struct Box {
        var type: String
        /// Everything after the 8-byte header.
        var body: Data
    }

    static func children(of data: Data) -> [Box] {
        var boxes: [Box] = []
        var offset = data.startIndex
        while offset + 8 <= data.endIndex {
            let size = Int(u32(data, offset - data.startIndex))
            guard size >= 8, offset + size <= data.endIndex else { break }
            boxes.append(Box(type: String(decoding: data[offset + 4..<offset + 8], as: UTF8.self), body: data[offset + 8..<offset + size]))
            offset += size
        }
        return boxes
    }

    /// The body of the box at `path`. Container boxes only, except for the last.
    static func find(_ path: [String], in data: Data) -> Data? {
        var current = data
        for type in path {
            guard let box = children(of: current).first(where: { $0.type == type }) else { return nil }
            current = box.body
        }
        return current
    }

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        data[data.startIndex + offset..<data.startIndex + offset + 2].reduce(0) { $0 << 8 | UInt16($1) }
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        data[data.startIndex + offset..<data.startIndex + offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
