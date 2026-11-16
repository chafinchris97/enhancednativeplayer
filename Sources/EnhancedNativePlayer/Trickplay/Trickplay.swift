import Foundation

/// Thumbnails for scrubbing, as sprite sheets: JPEG images each holding a grid of thumbnails,
/// in order, left to right then top to bottom, sheet after sheet. How many thumbnails there are
/// follows from the sheets and the file's length: one per `interval` to the end of the file, as
/// far as the sheets hold.
///
/// ```swift
/// Trickplay(width: 320, height: 180, tileWidth: 10, tileHeight: 10,
///           interval: 10_000, bandwidth: 13_849, sheets: (0..<7).map { sheetURL($0) })
/// ```
public struct Trickplay: Hashable, Sendable {
    /// One thumbnail's width in pixels.
    public var width: Int
    /// One thumbnail's height in pixels.
    public var height: Int
    /// Thumbnails across a sheet.
    public var tileWidth: Int
    /// Thumbnails down a sheet.
    public var tileHeight: Int
    /// Milliseconds of the file each thumbnail stands for: thumbnail k shows from k × interval.
    public var interval: Int
    /// Bits per second the sheets average over the file's duration.
    public var bandwidth: Int
    /// Every sheet, in order, fetched with the media's headers. All but the last are full.
    public var sheets: [URL]

    public init(width: Int, height: Int, tileWidth: Int, tileHeight: Int, interval: Int, bandwidth: Int, sheets: [URL]) {
        self.width = width
        self.height = height
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.interval = interval
        self.bandwidth = bandwidth
        self.sheets = sheets
    }

    var thumbnailsPerSheet: Int { tileWidth * tileHeight }

    /// Why the description can't be used, nil when it can.
    var problem: String? {
        if width <= 0 || height <= 0 { return "thumbnail size \(width)x\(height)" }
        if tileWidth <= 0 || tileHeight <= 0 { return "sheet layout \(tileWidth)x\(tileHeight)" }
        if interval <= 0 { return "interval \(interval) ms" }
        if sheets.isEmpty { return "no sheets" }
        return nil
    }

    /// The thumbnails there are for a file this long: one per `interval` to its end, as far as
    /// the sheets hold. The last sheet is the only one partly filled.
    func thumbnailCount(fileSeconds: Double) -> Int {
        let capacity = sheets.count * thumbnailsPerSheet
        let throughEnd = Int((fileSeconds * 1000 / Double(interval)).rounded(.up))
        return min(capacity, max(1, throughEnd))
    }
}

/// Where each thumbnail is, once their count is known.
struct TrickplayIndex: Sendable {
    let trickplay: Trickplay
    let count: Int

    /// Thumbnails in a sheet.
    func count(ofSheet sheet: Int) -> Int {
        max(0, min(trickplay.thumbnailsPerSheet, count - sheet * trickplay.thumbnailsPerSheet))
    }

    /// The sheet and the place in it of the thumbnail showing at a time in the file's timeline.
    /// Times before the first or past the last thumbnail get that thumbnail.
    func thumbnail(atFileSeconds seconds: Double) -> (sheet: Int, tile: Int) {
        let index = Int((seconds * 1000 / Double(trickplay.interval)).rounded(.down))
        let clamped = min(max(0, index), count - 1)
        return (clamped / trickplay.thumbnailsPerSheet, clamped % trickplay.thumbnailsPerSheet)
    }
}
