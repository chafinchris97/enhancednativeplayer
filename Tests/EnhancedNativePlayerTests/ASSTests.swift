import CoreGraphics
import Foundation
import EPLibass
import Testing
@testable import EnhancedNativePlayer

struct ASSTests {
    private let header = Array("""
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080
    YCbCr Matrix: None

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,72,&H000000FF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,10,10,40,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """.utf8)

    private func event(_ readOrder: Int, _ text: String, start: Int64, duration: Int64) -> ASSEvent {
        ASSEvent(startMilliseconds: start, durationMilliseconds: duration, data: Array("\(readOrder),0,Default,,0,0,0,,\(text)".utf8))
    }

    private func renderer(width: Int = 1920, height: Int = 1080) throws -> LibassRenderer {
        let renderer = try #require(LibassRenderer(header: header, fonts: [], videoMatrix: .bt709))
        renderer.set(layout: .init(frameWidth: width, frameHeight: height, video: CGRect(x: 0, y: 0, width: width, height: height), storageWidth: width, storageHeight: height))
        return renderer
    }

    @Test func eventShowsFromItsFirstMillisecondUntilItsEnd() throws {
        let renderer = try renderer()
        renderer.add([event(0, "Hello", start: 1001, duration: 2002)])
        #expect(renderer.render(atMilliseconds: 1000).image == nil)
        #expect(renderer.render(atMilliseconds: 1001).image != nil)
        #expect(renderer.render(atMilliseconds: 3002).image != nil)
        #expect(renderer.render(atMilliseconds: 3003).image == nil)
    }

    @Test func duplicateReadOrderIsIgnored() throws {
        let renderer = try renderer()
        renderer.add([event(7, "Once", start: 0, duration: 1000)])
        let single = try #require(renderer.render(atMilliseconds: 500).image)
        renderer.add([event(7, "Once", start: 0, duration: 1000)])
        let again = try #require(renderer.render(atMilliseconds: 500).image)
        #expect(single.width == again.width && single.height == again.height)
    }

    @Test func unchangedFrameIsReused() throws {
        let renderer = try renderer()
        renderer.add([event(0, "Still", start: 0, duration: 5000)])
        let first = try #require(renderer.render(atMilliseconds: 100).image)
        let second = try #require(renderer.render(atMilliseconds: 200).image)
        #expect(first === second)
    }

    @Test func textIsDrawnInItsColourInsideTheVideo() throws {
        // A 4:3 picture pillarboxed in a 16:9 frame: the text stays over the picture.
        let renderer = try #require(LibassRenderer(header: header, fonts: [], videoMatrix: .bt709))
        renderer.set(layout: .init(frameWidth: 1920, frameHeight: 1080, video: CGRect(x: 240, y: 0, width: 1440, height: 1080), storageWidth: 1440, storageHeight: 1080))
        renderer.add([event(0, "{\\an7\\pos(0,0)}X", start: 0, duration: 1000)])
        let frame = renderer.render(atMilliseconds: 0)
        let image = try #require(frame.image)
        #expect(frame.rect.minX >= 240)
        // Opaque red somewhere: the style's primary colour is &H000000FF (BGR).
        let data = try #require(image.dataProvider?.data as Data?)
        let pixels = [UInt8](data)
        var red = false
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let bgra = (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
            if bgra == (0, 0, 255, 255) { red = true }
        }
        #expect(red)
    }

    @Test func millisecondsRoundToNearest() {
        #expect(ASSTime.milliseconds(ticks: 10_010_000) == 1001)
        #expect(ASSTime.milliseconds(ticks: 10_014_999) == 1001)
        #expect(ASSTime.milliseconds(ticks: 10_015_000) == 1002)
        #expect(ASSTime.milliseconds(ticks: -10_000) == -1)
        #expect(ASSTime.milliseconds(ticks: -14_000) == -1)
        #expect(ASSTime.milliseconds(ticks: -16_000) == -2)
    }

    @Test func standardFrameRatesAreExact() {
        // A demuxer's approximate average rate means the exact standard one; anything else isn't trusted.
        #expect(ASSTime.frameTicks(forRate: 23.98) == 10_000_000.0 * 1001 / 24000)
        #expect(ASSTime.frameTicks(forRate: 25) == 400_000)
        #expect(ASSTime.frameTicks(forRate: 17.3) == nil)
    }

    @Test func coloursAreMangledLikeVSFilter() throws {
        // No header: TV.601, so on BT.709 video colours shift; on BT.601 video they don't.
        #expect(ColorMangling(header: YCBCR_DEFAULT, video: .bt601) == nil)
        #expect(ColorMangling(header: YCBCR_NONE, video: .bt709) == nil)
        #expect(ColorMangling(header: YCBCR_BT709_TV, video: .bt709) == nil)
        let mangling = try #require(ColorMangling(header: YCBCR_DEFAULT, video: .bt709))
        // Greys have no chroma and survive; alpha is kept.
        #expect(mangling.apply(0x8080_8040) == 0x8080_8040)
        // Pure red read as 601 YCbCr and shown as 709 comes out with green lifted.
        let red = mangling.apply(0xFF00_0000)
        #expect(red >> 16 & 0xFF > 0)
        #expect(red & 0xFF == 0)
    }
}
