import Compression
import CoreGraphics
import Testing
@testable import EnhancedNativePlayer

struct PGSTests {
    /// White, fully opaque in limited range.
    private let white: [UInt8] = [1, 235, 128, 128, 255]

    private func segment(_ type: UInt8, _ body: [UInt8]) -> [UInt8] {
        [type, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    }

    private func presentation(state: UInt8 = 0x80, objects: [[UInt8]] = [], canvas: (Int, Int) = (1920, 1080)) -> [UInt8] {
        let size: [UInt8] = [UInt8(canvas.0 >> 8), UInt8(canvas.0 & 0xFF), UInt8(canvas.1 >> 8), UInt8(canvas.1 & 0xFF)]
        return segment(0x16, size + [0x10, 0, 1, state, 0, 0, UInt8(objects.count)] + objects.flatMap { $0 })
    }

    /// Object 0 at (x, y) 16-bit.
    private func placement(x: UInt8, y: UInt8, crop: [UInt8]? = nil) -> [UInt8] {
        [0, 0, 0, crop == nil ? 0 : 0x80, 0, x, 0, y] + (crop ?? [])
    }

    private func palette(_ entries: [UInt8]) -> [UInt8] { segment(0x14, [0, 0] + entries) }

    private func object(width: UInt8, height: UInt8, rle: [UInt8]) -> [UInt8] {
        let length = rle.count + 4
        return segment(0x15, [0, 0, 0, 0xC0, 0, UInt8(length >> 8), UInt8(length & 0xFF), 0, width, 0, height] + rle)
    }

    private let end: [UInt8] = [0x80, 0, 0]

    private func sets(_ packets: [([UInt8], Int64)]) -> [PGSDisplaySet] {
        var parser = PGSParser()
        for (payload, ticks) in packets { parser.append(payload: payload, ticks: ticks) }
        return parser.finish()
    }

    @Test func decodesEveryRunLengthForm() throws {
        // 1 (one pixel), 00 02 (two of 0), 00 83 01 (three of 1), end of line, 00 01 (one of 0), 00 C0 02 01 (two of 1).
        let rle: [UInt8] = [1, 0, 2, 0, 0x83, 1, 0, 0, 0, 1, 0, 0xC0, 2, 1, 0, 0]
        let packet = presentation(objects: [placement(x: 10, y: 20)]) + palette(white) + object(width: 6, height: 2, rle: rle) + end
        let frame = try #require(PGSCompositor.replay(sets([(packet, 5)])).frames.first)
        #expect(frame.startTicks == 5)
        let bitmap = try #require(frame.bitmaps.first)
        #expect((bitmap.x, bitmap.y, bitmap.width, bitmap.height) == (10, 20, 6, 2))
        let w: UInt32 = 0xFFFF_FFFF
        #expect(bitmap.pixels() == [w, 0, 0, w, w, w, 0, w, w, 0, 0, 0])
        #expect(bitmap.makeImage()?.width == 6)
    }

    @Test func survivesATruncatedBitmap() throws {
        let packet = presentation(objects: [placement(x: 0, y: 0)]) + palette(white) + object(width: 2, height: 2, rle: [1, 0, 0x83]) + end
        let bitmap = try #require(PGSCompositor.replay(sets([(packet, 0)])).frames.first?.bitmaps.first)
        #expect(bitmap.pixels().count == 4)
    }

    @Test func cropKeepsOnlyItsRegion() throws {
        let crop: [UInt8] = [0, 1, 0, 0, 0, 2, 0, 1]
        let rle: [UInt8] = [1, 0, 0x81, 2, 1, 0, 0]
        let packet = presentation(objects: [placement(x: 0, y: 0, crop: crop)]) + palette(white + [2, 16, 128, 128, 255]) + object(width: 3, height: 1, rle: rle) + end
        let bitmap = try #require(PGSCompositor.replay(sets([(packet, 0)])).frames.first?.bitmaps.first)
        #expect((bitmap.width, bitmap.height) == (2, 1))
        #expect(bitmap.pixels() == [0xFF00_0000, 0xFFFF_FFFF])
    }

    @Test func objectSpanningSegmentsAndSplitPacketsAssemble() throws {
        // First part flagged 0x80, last flagged 0x40, every segment in a packet of its own.
        let first = segment(0x15, [0, 0, 0, 0x80, 0, 0, 7, 0, 2, 0, 1, 1])
        let last = segment(0x15, [0, 0, 0, 0x40, 1, 0, 0])
        let packets = [presentation(objects: [placement(x: 0, y: 0)]), palette(white), first, last, end].map { ($0, Int64(7)) }
        let bitmap = try #require(PGSCompositor.replay(sets(packets)).frames.first?.bitmaps.first)
        #expect(bitmap.pixels() == [0xFFFF_FFFF, 0xFFFF_FFFF])
    }

    @Test func laterSetsReuseTheEpochAndAClearIsAFrame() throws {
        let start = presentation(objects: [placement(x: 0, y: 0)]) + palette(white) + object(width: 1, height: 1, rle: [1, 0, 0]) + end
        // A fade: same object, new alpha. Then a clear.
        let fade = presentation(state: 0, objects: [placement(x: 0, y: 0)]) + palette([1, 235, 128, 128, 0]) + end
        let clear = presentation(state: 0) + end
        let (frames, isComplete) = PGSCompositor.replay(sets([(start, 0), (fade, 1), (clear, 2)]))
        #expect(isComplete)
        #expect(frames.map(\.startTicks) == [0, 1, 2])
        #expect(frames[1].bitmaps[0].pixels() == [0])
        #expect(frames[2].bitmaps.isEmpty)
    }

    @Test func aSetLeaningOnAnUnreadEpochIsIncomplete() {
        let fade = presentation(state: 0, objects: [placement(x: 0, y: 0)]) + palette(white) + end
        let (frames, isComplete) = PGSCompositor.replay(sets([(fade, 0)]))
        #expect(!isComplete)
        #expect(frames[0].bitmaps.isEmpty)
    }

    @Test func anEpochStartForgetsEarlierObjects() {
        let first = presentation(objects: [placement(x: 0, y: 0)]) + palette(white) + object(width: 1, height: 1, rle: [1, 0, 0]) + end
        let second = presentation(objects: [placement(x: 0, y: 0)]) + palette(white) + end
        #expect(!PGSCompositor.replay(sets([(first, 0), (second, 1)])).isComplete)
    }

    /// As mkvmerge writes a block: zlib's two-byte header, deflate, then a checksum nothing reads.
    private func zlib(_ bytes: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: bytes.count + 1024)
        let count = compression_encode_buffer(&output, output.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
        return [0x78, 0x9C] + output[..<count] + [0, 0, 0, 0]
    }

    @Test func compressedBlocksInflateIntoTheSameDisplaySet() throws {
        let packet = presentation(objects: [placement(x: 10, y: 20)]) + palette(white) + object(width: 1, height: 1, rle: [1, 0, 0]) + end
        #expect(MatroskaCompression.inflated(zlib(packet)) == packet)
        #expect(sets([(MatroskaCompression.inflated(zlib(packet)), 5)]) == sets([(packet, 5)]))
    }

    @Test func inflatingAPayloadBiggerThanTheFirstGuessGrows() {
        let large = [UInt8](repeating: 7, count: 1 << 20)
        #expect(MatroskaCompression.inflated(zlib(large)) == large)
    }

    @Test func whatIsNotZlibIsLeftAlone() {
        let pgs = presentation()
        #expect(MatroskaCompression.inflated(pgs) == pgs)
        let text = Array("Hello".utf8)
        #expect(MatroskaCompression.inflated(text) == text)
        // Passes the header check, but what follows isn't deflate.
        let lookalike: [UInt8] = [0x78, 0x9C, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(MatroskaCompression.inflated(lookalike) == lookalike)
    }

    @Test func canvasMapsToTheScreenNotTheVideo() {
        let object = PGSObject(width: 100, height: 50, rle: [])
        let bitmap = PGSBitmap(object: object, palette: [], isHighDefinition: true, x: 960, y: 900)
        let frame = PGSFrame(startTicks: 0, canvasWidth: 1920, canvasHeight: 1080, bitmaps: [bitmap])
        #expect(frame.rect(of: bitmap, in: CGSize(width: 3840, height: 2160)) == CGRect(x: 1920, y: 1800, width: 200, height: 100))
        #expect(frame.rect(of: bitmap, in: CGSize(width: 1920, height: 1080)) == CGRect(x: 960, y: 900, width: 100, height: 50))
        // A wider screen: the 16:9 canvas is centered.
        #expect(frame.rect(of: bitmap, in: CGSize(width: 2400, height: 1080)) == CGRect(x: 1200, y: 900, width: 100, height: 50))
    }
}
