import Testing
@testable import EnhancedNativePlayer

struct SegmentPlanTests {
    let ms = Rational(num: 1, den: 1000)

    @Test func cutsOnTheFixedGridFromTheFirstKeyframe() {
        // hlsenc targets 6, 12, 18 … from start_pts, not 6 s after each cut.
        let plan = SegmentPlan(keyframes: [0, 4000, 7000, 11000, 12500, 13000, 25000, 26000], timeBase: ms, hlsTime: 6, end: 30000)
        // 7 s meets 6, 12.5 meets 12, 25 meets 18, and 26 meets 24 right away.
        #expect(plan.segments.map(\.start) == [0, 7000, 12500, 25000, 26000])
    }

    @Test func longGopIsFollowedByCatchUpSegments() {
        // A 14 s GOP consumes targets 6 and 12; the next keyframe at 15 s meets 12 s at once.
        let plan = SegmentPlan(keyframes: [0, 14000, 15000, 16000, 19000], timeBase: ms, hlsTime: 6, end: 20000)
        #expect(plan.segments.map(\.start) == [0, 14000, 15000, 19000])
    }

    @Test func comparisonIsExactAtTheTarget() {
        // A keyframe exactly on the target cuts (>= 0), one tick before does not.
        let tb = Rational(num: 1001, den: 24000)
        let exact = SegmentPlan(keyframes: [0, 144, 288], timeBase: tb, hlsTime: 6.006, end: 300)
        #expect(exact.segments.map(\.start) == [0, 144, 288])
        let early = SegmentPlan(keyframes: [0, 143, 287], timeBase: tb, hlsTime: 6.006, end: 300)
        #expect(early.segments.map(\.start) == [0, 287])
    }

    @Test func durationsTicksAndTargetDuration() {
        let plan = SegmentPlan(keyframes: [1000, 7006, 13500], timeBase: ms, hlsTime: 6, end: 16000)
        #expect(plan.segments.map(\.duration) == [6.006, 6.494, 2.5])
        #expect(plan.segments.map(\.runtimeTicks) == [0, 60_060_000, 125_000_000])
        #expect(plan.targetDuration == 6)
        #expect(plan.segmentIndex(forRuntimeTicks: 60_060_000) == 1)
        #expect(plan.segmentIndex(forRuntimeTicks: 60_059_999) == 0)
    }

    @Test func exactArithmeticDoesNotOverflow() {
        let tb = Rational(num: 1, den: 1_000_000_000)
        #expect(SegmentPlan.compare(Int64.max / 2, tb, Int64.max / 2, tb) == 0)
        #expect(SegmentPlan.rescale(90_000 * 3600 * 30, Rational(num: 1, den: 90_000), .ticks) == 3600 * 30 * 10_000_000)
    }
}

struct FLACFrameHeaderTests {
    @Test func utf8CodingMatchesTheSpec() {
        #expect(FLACFrameHeader.utf8Coded(0) == [0x00])
        #expect(FLACFrameHeader.utf8Coded(0x7F) == [0x7F])
        #expect(FLACFrameHeader.utf8Coded(0x80) == [0xC2, 0x80])
        #expect(FLACFrameHeader.utf8Coded(0x7FF) == [0xDF, 0xBF])
        #expect(FLACFrameHeader.utf8Coded(0x800) == [0xE0, 0xA0, 0x80])
        #expect(FLACFrameHeader.utf8Coded(0x10000) == [0xF0, 0x90, 0x80, 0x80])
    }

    @Test func renumberKeepsCRCsValid() throws {
        // Header: sync, blocksize code 5 (4608), 48 kHz, 6ch/24-bit, frame 0, CRC-8, then payload + CRC-16.
        var frame: [UInt8] = [0xFF, 0xF8, 0x5A, 0x5C, 0x00]
        frame.append(FLACFrameHeader.crc8(frame))
        frame += [1, 2, 3, 4, 5]
        let crc = FLACFrameHeader.crc16(frame)
        frame += [UInt8(crc >> 8), UInt8(crc & 0xFF)]

        let renumbered = try #require(FLACFrameHeader.renumber(frame, frameNumber: 300))
        #expect(Array(renumbered[0..<4]) == [0xFF, 0xF8, 0x5A, 0x5C])
        #expect(Array(renumbered[4..<6]) == FLACFrameHeader.utf8Coded(300))
        #expect(renumbered[6] == FLACFrameHeader.crc8(Array(renumbered[0..<6])))
        #expect(Array(renumbered[7..<12]) == [1, 2, 3, 4, 5])
        let body = Array(renumbered.dropLast(2))
        let check = FLACFrameHeader.crc16(body)
        #expect(Array(renumbered.suffix(2)) == [UInt8(check >> 8), UInt8(check & 0xFF)])
    }

    @Test func routesParse() {
        #expect(HLSRoute(fileName: "master.m3u8") == .master)
        #expect(HLSRoute(fileName: "audio_3.m3u8") == .audioPlaylist(track: 3))
        #expect(HLSRoute(fileName: "init_video.mp4") == .videoInit)
        #expect(HLSRoute(fileName: "video_12.mp4") == .videoSegment(12))
        #expect(HLSRoute(fileName: "audio_1_init.mp4") == .audioInit(track: 1))
        #expect(HLSRoute(fileName: "audio_1_7.mp4") == .audioSegment(track: 1, index: 7))
        #expect(HLSRoute(fileName: "audio_x_7.mp4") == nil)
        #expect(HLSRoute(fileName: "other.ts") == nil)
    }
}
