import CoreGraphics
import Foundation
import EPLibass
import Testing
@testable import EnhancedNativePlayer

/// Heavy typesetting: how long one frame takes, libass and composing apart.
struct ASSBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENP_ASS_BENCH"] != nil)) func heavyFrames() async throws {
        let header = Array("""
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,64,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,3,2,2,10,10,40,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """.utf8)
        var events: [ASSEvent] = []
        // 60 animated signs with blur, glow layers and a karaoke line, all on screen at once.
        for i in 0..<60 {
            let x = 100 + (i % 10) * 170, y = 120 + (i / 10) * 150
            for layer in 0..<3 {
                let text = "{\\\\an5\\\\move(\(x),\(y),\(x + 40),\(y + 30))\\\\blur\(layer * 3 + 1)\\\\bord\(layer * 2 + 2)\\\\t(0,2000,\\\\frz30\\\\fscx130)\\\\3c&H\(String(format: "%02X", i * 4))40FF&}SIGN \(i)"
                events.append(ASSEvent(startMilliseconds: 0, durationMilliseconds: 10_000, data: Array("\(i * 3 + layer),\(layer),Default,,0,0,0,,\(text)".utf8)))
            }
        }
        events.append(ASSEvent(startMilliseconds: 0, durationMilliseconds: 10_000, data: Array("999,5,Default,,0,0,0,,{\\\\k20}Ka{\\\\k20}ra{\\\\k20}o{\\\\k20}ke {\\\\k20}line {\\\\k20}that {\\\\k20}sweeps".utf8)))
        // The whole engine, samples included, one worker against the default.
        for workers in [1, ASSRenderEngine.defaultWorkerCount] {
            let engine = try #require(ASSRenderEngine(header: header, fonts: [], videoMatrix: .bt709, workerCount: workers))
            engine.set(layout: .init(frameWidth: 3840, frameHeight: 2160, video: CGRect(x: 0, y: 0, width: 3840, height: 2160), storageWidth: 1920, storageHeight: 1080))
            engine.add(events)
            let frames = (0..<24).map { Int64($0) * 417_083 }
            let clock = ContinuousClock()
            let took = await clock.measure {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    engine.renderSamples(frames, end: 10_010_000, width: 3840, height: 2160) { _, _ in done.resume() }
                }
            }
            print("BENCH engine 3840x2160, \(workers) workers: \(took / 24) per frame")
        }
        for (width, height) in [(1920, 1080), (3840, 2160)] {
            let renderer = try #require(LibassRenderer(header: header, fonts: [], videoMatrix: .bt709))
            renderer.set(layout: .init(frameWidth: width, frameHeight: height, video: CGRect(x: 0, y: 0, width: width, height: height), storageWidth: 1920, storageHeight: 1080))
            renderer.add(events)
            _ = renderer.render(atMilliseconds: 0)
            let clock = ContinuousClock()
            let frames = 24
            let total = clock.measure {
                for frame in 1...frames { _ = renderer.render(atMilliseconds: Int64(frame) * 42) }
            }
            let perFrame = total / frames
            print("BENCH \(width)x\(height): \(perFrame) per frame (a 24 fps frame lasts 41.7 ms)")
        }
    }
}
