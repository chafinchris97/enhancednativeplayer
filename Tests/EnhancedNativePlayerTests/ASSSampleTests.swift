import CoreGraphics
import CoreMedia
import CoreVideo
import Testing
@testable import EnhancedNativePlayer

struct ASSSampleTests {
    private func solid(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func runsJoinFramesWithTheSameImage() {
        let a = ASSRenderedFrame(image: solid(width: 2, height: 2), rect: .zero)
        let b = ASSRenderedFrame(image: solid(width: 2, height: 2), rect: .zero)
        let empty = ASSRenderedFrame(image: nil, rect: .zero)
        let frames: [Int64] = [0, 417_083, 834_167, 1_251_250, 1_668_333]
        let runs = ASSSamples.runs(frames: frames, images: [empty, a, a, b, empty], end: 2_085_417)
        #expect(runs == [
            ASSSampleRun(start: 0, duration: 417_083, index: 0),
            ASSSampleRun(start: 417_083, duration: 834_167, index: 1),
            ASSSampleRun(start: 1_251_250, duration: 417_083, index: 3),
            ASSSampleRun(start: 1_668_333, duration: 417_084, index: 4),
        ])
    }

    @Test func sampleCarriesTheFrameTimingAndImageInPlace() throws {
        let factory = ASSSampleBufferFactory()
        // A 20×10 block 30 px from the left, 40 px from the top of a 100×80 canvas.
        let frame = ASSRenderedFrame(image: solid(width: 20, height: 10), rect: CGRect(x: 30, y: 40, width: 20, height: 10))
        let sample = try #require(factory.sample(for: frame, width: 100, height: 80, start: 100_417_083, duration: 417_084))
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 100_417_083, timescale: 10_000_000))
        #expect(CMSampleBufferGetDuration(sample) == CMTime(value: 417_084, timescale: 10_000_000))
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        #expect(CVPixelBufferGetWidth(buffer) == 100 && CVPixelBufferGetHeight(buffer) == 80)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        func pixel(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let p = base + y * row + x * 4
            return (p[0], p[1], p[2], p[3])
        }
        // Rows in memory run top to bottom, as the rect is given.
        func isGreen(_ p: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) -> Bool { p.a == 255 && p.g > 240 && p.r < 8 && p.b < 8 }
        #expect(isGreen(pixel(35, 45)))
        #expect(isGreen(pixel(49, 49)))
        // Everything else is fully transparent.
        #expect(pixel(35, 35).a == 0)
        #expect(pixel(35, 55).a == 0)
        #expect(pixel(0, 0) == (0, 0, 0, 0))
    }

    @Test func emptyFramesShareOneTransparentBuffer() throws {
        let factory = ASSSampleBufferFactory()
        let empty = ASSRenderedFrame(image: nil, rect: .zero)
        let first = try #require(factory.sample(for: empty, width: 64, height: 32, start: 0, duration: 1))
        let second = try #require(factory.sample(for: empty, width: 64, height: 32, start: 1, duration: 1))
        #expect(CMSampleBufferGetImageBuffer(first) === CMSampleBufferGetImageBuffer(second))
        // A new canvas size gets buffers of that size.
        let resized = try #require(factory.sample(for: empty, width: 32, height: 16, start: 2, duration: 1))
        #expect(CVPixelBufferGetWidth(try #require(CMSampleBufferGetImageBuffer(resized))) == 32)
    }

    @Test func chunksAreConsecutiveAndEven() {
        let frames: [Int64] = Array(0..<10)
        let chunks = ASSSamples.chunks(of: frames, count: 4)
        #expect(chunks == [[0, 1], [2, 3, 4], [5, 6], [7, 8, 9]])
        #expect(ASSSamples.chunks(of: [1, 2], count: 4) == [[1], [2]])
        #expect(ASSSamples.chunks(of: frames, count: 1) == [frames])
    }

    @Test func mergedMakesAStillImageAcrossChunksOne() {
        // Two workers each composed the same still subtitle.
        let rect = CGRect(x: 0, y: 0, width: 4, height: 4)
        let a = ASSRenderedFrame(image: solid(width: 4, height: 4), rect: rect)
        let b = ASSRenderedFrame(image: solid(width: 4, height: 4), rect: rect)
        let other = ASSRenderedFrame(image: solid(width: 4, height: 4), rect: CGRect(x: 8, y: 0, width: 4, height: 4))
        let pieces = ASSSamples.merged([
            [ASSSamples.Piece(start: 0, duration: 2, frame: a)],
            [ASSSamples.Piece(start: 2, duration: 2, frame: b), ASSSamples.Piece(start: 4, duration: 1, frame: other)],
        ])
        #expect(pieces.count == 2)
        #expect(pieces[0].start == 0 && pieces[0].duration == 4 && pieces[0].retimed)
        #expect(pieces[1].frame.image === other.image && !pieces[1].retimed)
        // Different pictures stay apart, and so do empty and drawn frames.
        let empty = ASSRenderedFrame(image: nil, rect: .zero)
        #expect(ASSSamples.merged([[ASSSamples.Piece(start: 0, duration: 1, frame: a)], [ASSSamples.Piece(start: 1, duration: 1, frame: other)]]).count == 2)
        #expect(ASSSamples.merged([[ASSSamples.Piece(start: 0, duration: 1, frame: empty)], [ASSSamples.Piece(start: 1, duration: 1, frame: a)]]).count == 2)
        #expect(ASSSamples.merged([[ASSSamples.Piece(start: 0, duration: 1, frame: empty)], [ASSSamples.Piece(start: 1, duration: 1, frame: empty)]]).count == 1)
    }
}
