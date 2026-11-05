import CoreGraphics
import Foundation

/// A PGS object: the run-length coded indexed bitmap of one piece of subtitle.
struct PGSObject: Sendable, Equatable {
    var width: Int
    var height: Int
    var rle: [UInt8]
}

/// One PGS display set, as it is in the file. It can lean on objects
/// and palettes from earlier display sets of its epoch, so it shows nothing on its own.
struct PGSDisplaySet: Sendable, Equatable {
    struct Composition: Sendable, Equatable {
        var objectID: Int
        var x: Int
        var y: Int
        var crop: CGRect?
    }

    /// Position in the playlist timeline in 100 ns ticks.
    var startTicks: Int64
    var canvasWidth: Int
    var canvasHeight: Int
    var isEpochStart: Bool
    var paletteID: Int
    var compositions: [Composition] = []
    /// Each entry is packed as `Y << 24 | Cr << 16 | Cb << 8 | A`.
    var paletteEntries: [Int: [Int: UInt32]] = [:]
    var objects: [Int: PGSObject] = [:]
}

/// Collects display sets from packet payloads. A set usually fills one packet, but
/// a muxer can also give each of its segments a packet of its own.
struct PGSParser {
    private enum SegmentType {
        static let palette: UInt8 = 0x14
        static let object: UInt8 = 0x15
        static let presentation: UInt8 = 0x16
        static let end: UInt8 = 0x80
    }

    private var current: PGSDisplaySet?
    private var fragments: [Int: PGSObject] = [:]
    private var sets: [PGSDisplaySet] = []

    mutating func append(payload: [UInt8], ticks: Int64) {
        var offset = 0
        while offset + 3 <= payload.count {
            let type = payload[offset]
            let size = Self.u16(payload, offset + 1)
            let body = offset + 3
            guard body + size <= payload.count else { return }
            switch type {
            case SegmentType.presentation:
                finishSet()
                current = Self.presentation(payload[body..<(body + size)], ticks: ticks)
            case SegmentType.palette:
                palette(payload[body..<(body + size)])
            case SegmentType.object:
                object(payload[body..<(body + size)])
            case SegmentType.end:
                finishSet()
            default:
                break
            }
            offset = body + size
        }
    }

    /// Every display set so far, including one the read stopped short of ending.
    mutating func finish() -> [PGSDisplaySet] {
        finishSet()
        return sets
    }

    private mutating func finishSet() {
        if let current { sets.append(current) }
        current = nil
        fragments = [:]
    }

    private static func presentation(_ slice: ArraySlice<UInt8>, ticks: Int64) -> PGSDisplaySet? {
        let bytes = Array(slice)
        guard bytes.count >= 11 else { return nil }
        var set = PGSDisplaySet(
            startTicks: ticks,
            canvasWidth: u16(bytes, 0),
            canvasHeight: u16(bytes, 2),
            isEpochStart: bytes[7] & 0x80 != 0,
            paletteID: Int(bytes[9])
        )
        var offset = 11
        for _ in 0..<Int(bytes[10]) {
            guard offset + 8 <= bytes.count else { break }
            var composition = PGSDisplaySet.Composition(objectID: u16(bytes, offset), x: u16(bytes, offset + 4), y: u16(bytes, offset + 6))
            let cropped = bytes[offset + 3] & 0x80 != 0
            offset += 8
            if cropped {
                guard offset + 8 <= bytes.count else { break }
                composition.crop = CGRect(x: u16(bytes, offset), y: u16(bytes, offset + 2), width: u16(bytes, offset + 4), height: u16(bytes, offset + 6))
                offset += 8
            }
            set.compositions.append(composition)
        }
        return set
    }

    private mutating func palette(_ slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        guard current != nil, bytes.count >= 2 else { return }
        var entries = current?.paletteEntries[Int(bytes[0])] ?? [:]
        var offset = 2
        while offset + 5 <= bytes.count {
            entries[Int(bytes[offset])] = UInt32(bytes[offset + 1]) << 24 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 8 | UInt32(bytes[offset + 4])
            offset += 5
        }
        current?.paletteEntries[Int(bytes[0])] = entries
    }

    /// A large object spans several segments. Only the first says the size, and only
    /// the last, flagged 0x40, completes it.
    private mutating func object(_ slice: ArraySlice<UInt8>) {
        let bytes = Array(slice)
        guard current != nil, bytes.count >= 4 else { return }
        let id = Self.u16(bytes, 0)
        let flags = bytes[3]
        if flags & 0x80 != 0 {
            guard bytes.count >= 11 else { return }
            fragments[id] = PGSObject(width: Self.u16(bytes, 7), height: Self.u16(bytes, 9), rle: Array(bytes[11...]))
        } else {
            fragments[id]?.rle += bytes[4...]
        }
        if flags & 0x40 != 0, let object = fragments.removeValue(forKey: id), object.width > 0, object.height > 0 {
            current?.objects[id] = object
        }
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }
}

/// What is on screen from `startTicks` until the next frame. No bitmaps means a blank screen.
struct PGSFrame: Sendable, Equatable {
    var startTicks: Int64
    var canvasWidth: Int
    var canvasHeight: Int
    var bitmaps: [PGSBitmap]

    /// A bitmap's place in `bounds`. The canvas is the screen, not the video: subtitles
    /// authored on a 16:9 canvas keep their place however the video is letterboxed. A
    /// canvas of another shape is fitted and centered, as its video would be.
    func rect(of bitmap: PGSBitmap, in bounds: CGSize) -> CGRect {
        guard canvasWidth > 0, canvasHeight > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(canvasWidth), bounds.height / CGFloat(canvasHeight))
        let originX = (bounds.width - CGFloat(canvasWidth) * scale) / 2
        let originY = (bounds.height - CGFloat(canvasHeight) * scale) / 2
        return CGRect(
            x: originX + CGFloat(bitmap.x) * scale,
            y: originY + CGFloat(bitmap.y) * scale,
            width: CGFloat(bitmap.width) * scale,
            height: CGFloat(bitmap.height) * scale
        )
    }
}

/// An object placed on the canvas with the palette of its display set.
/// Pixels are decoded only for the frames that get shown.
struct PGSBitmap: Sendable, Equatable {
    var object: PGSObject
    /// 256 packed entries, as in `PGSDisplaySet`.
    var palette: [UInt32]
    var isHighDefinition: Bool
    var x: Int
    var y: Int
    var crop: CGRect?

    private var region: CGRect {
        let whole = CGRect(x: 0, y: 0, width: object.width, height: object.height)
        return crop?.intersection(whole) ?? whole
    }

    var width: Int { Int(region.width) }
    var height: Int { Int(region.height) }

    /// Premultiplied BGRA, top row first.
    func pixels() -> [UInt32] {
        let colors = palette.map { Self.bgra($0, isHighDefinition: isHighDefinition) }
        let region = region
        let left = Int(region.minX), top = Int(region.minY), width = Int(region.width), height = Int(region.height)
        guard width > 0, height > 0 else { return [] }
        var output = [UInt32](repeating: 0, count: width * height)
        let right = left + width, bottom = top + height
        let rle = object.rle
        let count = rle.count
        output.withUnsafeMutableBufferPointer { out in
            rle.withUnsafeBufferPointer { input in
                var i = 0, x = 0, y = 0
                while i < count, y < bottom {
                    var length = 1
                    var color = 0
                    let first = input[i]
                    i += 1
                    if first != 0 {
                        color = Int(first)
                    } else {
                        guard i < count else { break }
                        let flags = input[i]
                        i += 1
                        if flags == 0 {
                            x = 0
                            y += 1
                            continue
                        }
                        length = Int(flags & 0x3F)
                        if flags & 0x40 != 0 {
                            guard i < count else { break }
                            length = length << 8 | Int(input[i])
                            i += 1
                        }
                        if flags & 0x80 != 0 {
                            guard i < count else { break }
                            color = Int(input[i])
                            i += 1
                        }
                    }
                    if y >= top {
                        let from = max(x, left), to = min(x + length, right)
                        if from < to {
                            let value = colors[color]
                            let base = (y - top) * width - left
                            for column in from..<to { out[base + column] = value }
                        }
                    }
                    x += length
                }
            }
        }
        return output
    }

    func makeImage() -> CGImage? {
        let pixels = pixels()
        guard !pixels.isEmpty else { return nil }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Limited-range YCbCr to premultiplied BGRA: BT.709 above SD, BT.601 for SD, as
    /// libavcodec's PGS decoder chooses.
    private static func bgra(_ entry: UInt32, isHighDefinition: Bool) -> UInt32 {
        let alpha = Double(entry & 0xFF) / 255
        guard alpha > 0 else { return 0 }
        let y = 1.164 * (Double(entry >> 24) - 16)
        let cr = Double(entry >> 16 & 0xFF) - 128
        let cb = Double(entry >> 8 & 0xFF) - 128
        let red, green, blue: Double
        if isHighDefinition {
            red = y + 1.793 * cr
            green = y - 0.213 * cb - 0.533 * cr
            blue = y + 2.112 * cb
        } else {
            red = y + 1.596 * cr
            green = y - 0.392 * cb - 0.813 * cr
            blue = y + 2.017 * cb
        }
        func premultiplied(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 255) * alpha).rounded()) }
        return UInt32((alpha * 255).rounded()) << 24 | premultiplied(red) << 16 | premultiplied(green) << 8 | premultiplied(blue)
    }
}

/// Replays display sets in order the way a PGS decoder keeps its state: an epoch start
/// forgets everything, and objects and palette entries otherwise last until replaced.
enum PGSCompositor {
    static func replay(_ sets: [PGSDisplaySet]) -> (frames: [PGSFrame], isComplete: Bool) {
        var objects: [Int: PGSObject] = [:]
        var palettes: [Int: [UInt32]] = [:]
        var frames: [PGSFrame] = []
        var isComplete = true
        for set in sets {
            if set.isEpochStart {
                objects = [:]
                palettes = [:]
            }
            objects.merge(set.objects) { $1 }
            for (id, entries) in set.paletteEntries {
                var palette = palettes[id] ?? [UInt32](repeating: 0, count: 256)
                for (index, entry) in entries where index < 256 { palette[index] = entry }
                palettes[id] = palette
            }
            var bitmaps: [PGSBitmap] = []
            for composition in set.compositions {
                guard let object = objects[composition.objectID], let palette = palettes[set.paletteID] else {
                    isComplete = false
                    continue
                }
                bitmaps.append(PGSBitmap(
                    object: object,
                    palette: palette,
                    isHighDefinition: set.canvasHeight > 576,
                    x: composition.x,
                    y: composition.y,
                    crop: composition.crop
                ))
            }
            frames.append(PGSFrame(startTicks: set.startTicks, canvasWidth: set.canvasWidth, canvasHeight: set.canvasHeight, bitmaps: bitmaps))
        }
        return (frames, isComplete)
    }
}
