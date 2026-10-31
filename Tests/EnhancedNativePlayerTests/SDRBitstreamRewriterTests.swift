import AVFoundation
import Testing
@testable import EnhancedNativePlayer

struct SDRBitstreamRewriterTests {
    /// Writes SPS syntax elements MSB first.
    private struct BitWriter {
        private(set) var bits: [UInt8] = []

        mutating func u(_ count: Int, _ value: Int) {
            for i in (0..<count).reversed() { bits.append(UInt8(value >> i & 1)) }
        }

        mutating func ue(_ value: Int) {
            let code = value + 1
            let length = Int.bitWidth - code.leadingZeroBitCount
            u(length - 1, 0)
            u(length, code)
        }

        var bytes: [UInt8] {
            var padded = bits + [1]
            while padded.count % 8 != 0 { padded.append(0) }
            return stride(from: 0, to: padded.count, by: 8).map { start in
                padded[start..<start + 8].reduce(0) { $0 << 1 | $1 }
            }
        }
    }

    /// An HEVC SPS exercising sub-layers, an explicit and an inter-predicted short-term
    /// RPS, long-term pictures and an aspect ratio ahead of the colour description.
    private func hevcSPS(primaries: Int = 9, transfer: Int = 16, matrix: Int = 9, colourDescription: Bool = true) -> [UInt8] {
        var w = BitWriter()
        w.u(16, 0x4201)
        w.u(4, 0)
        w.u(3, 1)                       // sps_max_sub_layers_minus1
        w.u(1, 1)
        for _ in 0..<12 { w.u(8, 0x11) } // general profile_tier_level
        w.u(1, 1); w.u(1, 1)            // sub-layer profile and level present
        w.u(14, 0)                      // reserved_zero_2bits for i = 1..<8
        for _ in 0..<11 { w.u(8, 0) }   // sub-layer profile
        w.u(8, 0)                       // sub-layer level
        w.ue(0); w.ue(1)                // sps id, chroma
        w.ue(3840); w.ue(2160)
        w.u(1, 1); for _ in 0..<4 { w.ue(1) } // conformance window
        w.ue(2); w.ue(2)                // 10 bit
        w.ue(4)                         // log2_max_poc_lsb_minus4 → 8 bits
        w.u(1, 1)                       // sub-layer ordering info for both layers
        for _ in 0..<6 { w.ue(1) }
        for _ in 0..<6 { w.ue(1) }      // block sizes
        w.u(1, 0)                       // scaling lists
        w.u(2, 3)                       // amp, sao
        w.u(1, 0)                       // pcm
        w.ue(2)                         // two short-term sets
        w.ue(1); w.ue(1)                // set 0: one negative, one positive
        w.ue(0); w.u(1, 1); w.ue(0); w.u(1, 1)
        w.u(1, 1); w.u(1, 0); w.ue(0)   // set 1: inter RPS over 2 + 1 entries
        w.u(1, 1); w.u(1, 0); w.u(1, 1); w.u(1, 1)
        w.u(1, 1); w.ue(1); w.u(8, 5); w.u(1, 1) // one long-term picture
        w.u(2, 3)                       // temporal mvp, strong intra smoothing
        w.u(1, 1)                       // VUI
        w.u(1, 1); w.u(8, 255); w.u(32, 0x00010001) // Extended_SAR
        w.u(1, 1); w.u(1, 0)            // overscan
        w.u(1, 1); w.u(3, 5); w.u(1, 0) // video signal, video_format, full range
        w.u(1, colourDescription ? 1 : 0)
        if colourDescription {
            w.u(8, primaries); w.u(8, transfer); w.u(8, matrix)
        }
        w.u(1, 0)                       // chroma loc (a marker for what follows)
        return SDRBitstreamRewriter.addEmulationPrevention(w.bytes)
    }

    private func h264SPS(profile: Int = 100) -> [UInt8] {
        var w = BitWriter()
        w.u(8, 0x67); w.u(8, profile); w.u(8, 0); w.u(8, 51)
        w.ue(0)
        w.ue(1); w.ue(2); w.ue(2); w.u(1, 0)
        w.u(1, 1)                       // scaling matrix with one list present
        w.u(1, 1); w.ue(0); for _ in 1..<16 { w.ue(0) } // delta 0 throughout
        for _ in 1..<8 { w.u(1, 0) }
        w.ue(0)
        w.ue(0); w.ue(2)                // poc type 0
        w.ue(4); w.u(1, 0)
        w.ue(239); w.ue(134)
        w.u(1, 1); w.u(1, 1); w.u(1, 0) // frame_mbs_only, direct 8x8, no crop
        w.u(1, 1); w.u(1, 0); w.u(1, 0)
        w.u(1, 1); w.u(3, 5); w.u(1, 0); w.u(1, 1)
        w.u(8, 9); w.u(8, 16); w.u(8, 9)
        w.u(1, 0)
        return SDRBitstreamRewriter.addEmulationPrevention(w.bytes)
    }

    private func hvcC(arrays: [(type: UInt8, nals: [[UInt8]])]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 23)
        out[0] = 1
        out[21] = 3
        out[22] = UInt8(arrays.count)
        for array in arrays {
            out += [array.type, 0, UInt8(array.nals.count)]
            for nal in array.nals { out += [UInt8(nal.count >> 8), UInt8(nal.count & 0xFF)] + nal }
        }
        return out
    }

    private func lengthPrefixed(_ nals: [[UInt8]]) -> [UInt8] {
        nals.flatMap { nal in [0, 0, UInt8(nal.count >> 8), UInt8(nal.count & 0xFF)] + nal }
    }

    @Test func hevcColourDescriptionIsOverwrittenAndNothingElse() {
        let source = hevcSPS()
        #expect(SDRBitstreamRewriter.rewriteSPS(source, codec: .hevc) == hevcSPS(primaries: 1, transfer: 1, matrix: 1))
    }

    @Test func h264ColourDescriptionIsOverwritten() {
        let rewritten = SDRBitstreamRewriter.removeEmulationPrevention(SDRBitstreamRewriter.rewriteSPS(h264SPS(), codec: .h264))
        let source = SDRBitstreamRewriter.removeEmulationPrevention(h264SPS())
        #expect(rewritten != source)
        #expect(rewritten.count == source.count)
        // Rewriting twice changes nothing more.
        #expect(SDRBitstreamRewriter.rewriteSPS(SDRBitstreamRewriter.rewriteSPS(h264SPS(), codec: .h264), codec: .h264) == SDRBitstreamRewriter.rewriteSPS(h264SPS(), codec: .h264))
    }

    @Test func spsWithoutColourDescriptionIsLeftAlone() {
        let source = hevcSPS(colourDescription: false)
        #expect(SDRBitstreamRewriter.rewriteSPS(source, codec: .hevc) == source)
    }

    @Test func truncatedSPSIsLeftAlone() {
        let source = Array(hevcSPS().prefix(20))
        #expect(SDRBitstreamRewriter.rewriteSPS(source, codec: .hevc) == source)
    }

    @Test func emulationPreventionRoundTrips() {
        let rbsp: [UInt8] = [0x42, 0, 0, 1, 0, 0, 0, 3, 0, 0, 4, 9]
        let escaped = SDRBitstreamRewriter.addEmulationPrevention(rbsp)
        #expect(escaped == [0x42, 0, 0, 3, 1, 0, 0, 3, 0, 3, 0, 0, 4, 9])
        #expect(SDRBitstreamRewriter.removeEmulationPrevention(escaped) == rbsp)
    }

    @Test func hvcCDropsSEIAndRewritesSPS() throws {
        let vps: [UInt8] = [0x40, 0x01, 0x0C]
        let sei: [UInt8] = [0x4E, 0x01, 0x89, 0x80]
        let record = hvcC(arrays: [(32, [vps]), (33, [hevcSPS()]), (39, [sei])])
        let rewriter = try #require(SDRBitstreamRewriter(codec: .hevc, extradata: record))
        #expect(rewriter.extradata == hvcC(arrays: [(32, [vps]), (33, [hevcSPS(primaries: 1, transfer: 1, matrix: 1)])]))
    }

    @Test func annexBExtradataIsRefused() {
        #expect(SDRBitstreamRewriter(codec: .hevc, extradata: [0, 0, 0, 1, 0x42, 0x01]) == nil)
    }

    @Test func packetsLoseSEIAndDolbyVisionNALUnits() throws {
        let rewriter = try #require(SDRBitstreamRewriter(codec: .hevc, extradata: hvcC(arrays: [])))
        let aud: [UInt8] = [0x46, 0x01, 0x50]
        let prefixSEI: [UInt8] = [0x4E, 0x01, 0x89]
        let slice: [UInt8] = [0x26, 0x01, 0xAF, 0x10]
        let suffixSEI: [UInt8] = [0x50, 0x01, 0x84]
        let rpu: [UInt8] = [0x7C, 0x01, 0x19]
        let enhancement: [UInt8] = [0x7E, 0x01, 0x26]
        let packet = lengthPrefixed([aud, prefixSEI, slice, suffixSEI, rpu, enhancement])
        let result = packet.withUnsafeBufferPointer { rewriter.rewrite($0) }
        #expect(result == lengthPrefixed([aud, slice]))
    }

    @Test func cleanPacketsAreNotCopied() throws {
        let rewriter = try #require(SDRBitstreamRewriter(codec: .hevc, extradata: hvcC(arrays: [])))
        let packet = lengthPrefixed([[0x26, 0x01, 0xAF], [0x02, 0x01, 0xD0]])
        #expect(packet.withUnsafeBufferPointer { rewriter.rewrite($0) } == nil)
    }

    @Test func inBandSPSIsRewritten() throws {
        let rewriter = try #require(SDRBitstreamRewriter(codec: .hevc, extradata: hvcC(arrays: [])))
        let slice: [UInt8] = [0x26, 0x01, 0xAF]
        let packet = lengthPrefixed([hevcSPS(), slice])
        let result = packet.withUnsafeBufferPointer { rewriter.rewrite($0) }
        #expect(result == lengthPrefixed([hevcSPS(primaries: 1, transfer: 1, matrix: 1), slice]))
    }

    @Test func malformedPacketsPassThrough() throws {
        let rewriter = try #require(SDRBitstreamRewriter(codec: .hevc, extradata: hvcC(arrays: [])))
        let packet: [UInt8] = [0, 0, 0, 200, 0x4E, 0x01]
        #expect(packet.withUnsafeBufferPointer { rewriter.rewrite($0) } == nil)
    }

    @Test func sdrRoutes() {
        #expect(HLSRoute(fileName: "master_sdr.m3u8") == .sdrMaster)
        #expect(HLSRoute(fileName: "video_sdr.m3u8") == .sdrVideoPlaylist)
        #expect(HLSRoute(fileName: "init_video_sdr.mp4") == .sdrVideoInit)
        #expect(HLSRoute(fileName: "video_sdr_12.mp4") == .sdrVideoSegment(12))
        #expect(HLSRoute(fileName: "video_12.mp4") == .videoSegment(12))
    }
}

struct HEVCConfigurationRecordTests {
    private let vps: [UInt8] = [0x40, 0x01, 0x0C]
    private let sps: [UInt8] = [0x42, 0x01, 0x01]
    private let pps: [UInt8] = [0x44, 0x01, 0xC0]
    private let aud: [UInt8] = [0x46, 0x01, 0x50]
    private let slice: [UInt8] = [0x26, 0x01, 0xAF]

    private var empty: [UInt8] {
        var record = [UInt8](repeating: 0, count: 23)
        record[0] = 1
        record[21] = 0x0F
        return record
    }

    private func sample(_ nals: [[UInt8]]) -> [UInt8] {
        nals.flatMap { [0, 0, 0, UInt8($0.count)] + $0 }
    }

    private func filling(_ record: [UInt8], _ nals: [[UInt8]]) -> [UInt8]? {
        sample(nals).withUnsafeBufferPointer { HEVCConfigurationRecord.filling(record, from: $0) }
    }

    @Test func emptyRecordGetsTheInBandSets() {
        let expected = Array(empty[0..<22]) + [3]
            + [32, 0, 1, 0, 3] + vps
            + [33, 0, 1, 0, 3] + sps
            + [34, 0, 1, 0, 3] + pps
        #expect(filling(empty, [aud, vps, sps, pps, slice]) == expected)
    }

    @Test func recordWithArraysIsLeftAlone() {
        var record = empty
        record[22] = 1
        #expect(filling(record + [32, 0, 1, 0, 3] + vps, [vps, sps, pps, slice]) == nil)
    }

    @Test func sampleWithoutEverySetChangesNothing() {
        #expect(filling(empty, [vps, sps, slice]) == nil)
    }

    @Test func truncatedSampleChangesNothing() {
        let bytes: [UInt8] = [0, 0, 0, 200, 0x40, 0x01]
        #expect(bytes.withUnsafeBufferPointer { HEVCConfigurationRecord.filling(empty, from: $0) } == nil)
    }

    @Test func filledRecordSurvivesTheSDRRewrite() throws {
        let filled = try #require(filling(empty, [vps, sps, pps, slice]))
        let rewriter = try #require(SDRBitstreamRewriter(codec: .hevc, extradata: filled))
        #expect(rewriter.extradata == filled)
    }
}

struct DisplayRefusalTests {
    @Test func recognisesDisplayRefusalsOnly() {
        #expect(DisplayRefusal.matches(NSError(domain: AVFoundationErrorDomain, code: -11868)))
        #expect(DisplayRefusal.matches(NSError(domain: AVFoundationErrorDomain, code: -11848)))
        #expect(DisplayRefusal.matches(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL)))
        #expect(!DisplayRefusal.matches(NSError(domain: AVFoundationErrorDomain, code: -11800)))
        #expect(!DisplayRefusal.matches(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        #expect(!DisplayRefusal.matches(NSError(domain: "CoreMediaErrorDomain", code: -11868)))
    }
}

@MainActor
struct DisplayModeSwitchTests {
    @Test func returnsAfterTheTimeoutWhenNoSwitchStarts() async throws {
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await DisplayModeSwitch.wait(isSwitching: { false }, startTimeout: .milliseconds(100), settle: .seconds(60), poll: .milliseconds(5))
        }
        #expect(elapsed >= .milliseconds(100) && elapsed < .seconds(30))
    }

    @Test func waitsForTheEndOfTheSwitchPlusSettle() async throws {
        let clock = ContinuousClock()
        let begin = clock.now
        let elapsed = try await clock.measure {
            try await DisplayModeSwitch.wait(
                isSwitching: { let t = begin.duration(to: clock.now); return t > .milliseconds(50) && t < .milliseconds(150) },
                startTimeout: .seconds(60),
                settle: .milliseconds(100),
                poll: .milliseconds(5)
            )
        }
        #expect(elapsed >= .milliseconds(250) && elapsed < .seconds(30))
    }

    @Test func cancellationEndsTheWait() async {
        let task = Task { @MainActor in
            try await DisplayModeSwitch.wait(isSwitching: { true }, poll: .milliseconds(5))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
