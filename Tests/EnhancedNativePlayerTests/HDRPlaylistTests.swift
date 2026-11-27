import Foundation
import Testing
@testable import EnhancedNativePlayer

/// How the master announces Dolby Vision and HDR10+. Dolby Vision: profile 8 as one HEVC variant with
/// `SUPPLEMENTAL-CODECS`, profile 5 as `dvh1`.
struct DolbyVisionPlaylistTests {
    // hvcC: Main 10, Main 10 compatibility, level 153.
    private let hvcC: [UInt8] = [1, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 153]

    private func video(profile: Int, compatibilityID: Int, range: VideoRange) -> VideoTrack {
        VideoTrack(
            streamIndex: 0, codec: .hevc, timeBase: Rational(num: 1, den: 1000), width: 3840, height: 2160, frameRate: 24,
            frameDuration: 42, reorderDepth: 0, bitRate: nil, range: range,
            dolbyVision: DolbyVisionConfiguration(
                profile: profile, level: 6, rpuPresent: true, enhancementLayerPresent: false,
                baseLayerPresent: true, compatibilityID: compatibilityID
            ),
            extradata: hvcC, profile: 2, level: 153
        )
    }

    private func streamLines(_ video: VideoTrack) -> [Substring] {
        let ms = Rational(num: 1, den: 1000)
        let media = MediaInfo(
            formatName: "matroska", fileSize: 1_000_000, durationSeconds: 12, bitRate: nil, video: video,
            audio: [], subtitles: [],
            keyframes: KeyframeIndex(timestamps: [0, 6000], positions: [0, 1], timeBase: ms, usesDecodeTimestamps: false, presentationOffset: 0),
            videoEndTimestamp: 12000
        )
        let plan = SegmentPlan(keyframes: media.keyframes.timestamps, timeBase: ms, hlsTime: 6, end: media.videoEndTimestamp)
        let master = PlaylistBuilder(media: media, plan: plan, subtitleGrid: SubtitleGrid(totalTicks: 120_000_000)).master()
        return master.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
    }

    @Test(arguments: [(1, VideoRange.pq, "db1p"), (4, .hlg, "db4h"), (2, .sdr, "db2g")])
    func profile8IsOneHEVCVariantWithSupplementalCodecs(compatibilityID: Int, range: VideoRange, brand: String) {
        let track = video(profile: 8, compatibilityID: compatibilityID, range: range)
        let lines = streamLines(track)
        #expect(lines.count == 1)
        #expect(lines[0].contains("CODECS=\"hvc1.2.4.L153.90\""))
        #expect(lines[0].contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/\(brand)\""))
        #expect(lines[0].contains("VIDEO-RANGE=\(range.rawValue)"))
        #expect(track.sampleEntry == "hvc1")
    }

    @Test func profile5IsDvh1WithoutSupplementalCodecs() {
        let track = video(profile: 5, compatibilityID: 0, range: .pq)
        let lines = streamLines(track)
        #expect(lines.count == 1)
        #expect(lines[0].contains("CODECS=\"dvh1.05.06\""))
        #expect(!lines[0].contains("SUPPLEMENTAL-CODECS"))
        #expect(track.sampleEntry == "dvh1")
    }
}

/// HDR10+ detection in the first sample, and its `cdm4` announcement.
struct HDR10PlusTests {
    private let hvcC: [UInt8] = [1, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 153] + Array(repeating: 0, count: 8) + [0x03, 0]

    /// A length-prefixed prefix SEI NAL unit with one message.
    private func sei(type: UInt8, payload: [UInt8]) -> [UInt8] {
        let nal: [UInt8] = [39 << 1, 1, type, UInt8(payload.count)] + payload + [0x80]
        return [0, 0, 0, UInt8(nal.count)] + nal
    }

    private let slice: [UInt8] = [0, 0, 0, 3, 19 << 1, 1, 0xAF]
    /// T.35 header for HDR10+, then a little ST 2094-40 body with an emulation prevention byte.
    private let hdr10PlusPayload: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01, 0x40, 0x00, 0x00, 0x03, 0x01]

    @Test func findsTheT35Message() {
        // Mastering display colour volume (137) first, then HDR10+.
        let sample = sei(type: 137, payload: Array(repeating: 0x11, count: 24)) + sei(type: 4, payload: hdr10PlusPayload) + slice
        #expect(HDR10Plus.isPresent(in: sample, hvcC: hvcC))
    }

    @Test func ignoresOtherT35Messages() {
        // Same country and provider, a different application.
        var payload = hdr10PlusPayload
        payload[5] = 0x05
        #expect(!HDR10Plus.isPresent(in: sei(type: 4, payload: payload) + slice, hvcC: hvcC))
        #expect(!HDR10Plus.isPresent(in: slice, hvcC: hvcC))
    }

    @Test func masterAddsTheCdm4Brand() {
        let ms = Rational(num: 1, den: 1000)
        var video = VideoTrack(
            streamIndex: 0, codec: .hevc, timeBase: ms, width: 3840, height: 2160, frameRate: 24,
            frameDuration: 42, reorderDepth: 0, bitRate: nil, range: .pq, dolbyVision: nil,
            extradata: hvcC, profile: 2, level: 153
        )
        video.hdr10Plus = true
        let media = MediaInfo(
            formatName: "matroska", fileSize: 1_000_000, durationSeconds: 12, bitRate: nil, video: video,
            audio: [], subtitles: [],
            keyframes: KeyframeIndex(timestamps: [0, 6000], positions: [0, 1], timeBase: ms, usesDecodeTimestamps: false, presentationOffset: 0),
            videoEndTimestamp: 12000
        )
        let plan = SegmentPlan(keyframes: media.keyframes.timestamps, timeBase: ms, hlsTime: 6, end: media.videoEndTimestamp)
        let builder = PlaylistBuilder(media: media, plan: plan, subtitleGrid: SubtitleGrid(totalTicks: 120_000_000))
        let lines = builder.master().split(separator: "\n").filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        #expect(lines.count == 1)
        #expect(lines[0].contains("CODECS=\"hvc1.2.4.L153.90\""))
        #expect(lines[0].contains("SUPPLEMENTAL-CODECS=\"hvc1.2.4.L153.90/cdm4\""))
        #expect(lines[0].contains("VIDEO-RANGE=PQ"))
        #expect(!builder.master(sdr: true).contains("cdm4"))
    }

    @Test func mediaPlaylistsBeginWhereTheyAreToldTo() {
        let ms = Rational(num: 1, den: 1000)
        let plan = SegmentPlan(keyframes: [0, 6000], timeBase: ms, hlsTime: 6, end: 12000)
        let video = VideoTrack(
            streamIndex: 0, codec: .hevc, timeBase: ms, width: 3840, height: 2160, frameRate: 24,
            frameDuration: 42, reorderDepth: 0, bitRate: nil, range: .pq, dolbyVision: nil,
            extradata: hvcC, profile: 2, level: 153
        )
        let media = MediaInfo(
            formatName: "matroska", fileSize: 1_000_000, durationSeconds: 12, bitRate: nil, video: video,
            audio: [], subtitles: [],
            keyframes: KeyframeIndex(timestamps: [0, 6000], positions: [0, 1], timeBase: ms, usesDecodeTimestamps: false, presentationOffset: 0),
            videoEndTimestamp: 12000
        )
        let builder = PlaylistBuilder(media: media, plan: plan, subtitleGrid: SubtitleGrid(totalTicks: 120_000_000))
        for playlist in [builder.videoPlaylist(start: 7.25), builder.sdrVideoPlaylist(start: 7.25), builder.audioPlaylist(track: 0, start: 7.25)] {
            let lines = playlist.split(separator: "\n")
            let start = lines.firstIndex(of: "#EXT-X-START:TIME-OFFSET=7.250,PRECISE=YES")
            #expect(start != nil)
            #expect(start.map { $0 < lines.firstIndex { $0.hasPrefix("#EXTINF") }! } == true)
        }
        #expect(!builder.videoPlaylist().contains("EXT-X-START"))
        #expect(!builder.videoPlaylist(start: 0).contains("EXT-X-START"))
    }
}

/// The init summary the server logs, read back from a sample entry with a dvvC.
struct InitDescriptionTests {
    @Test func readsTheDolbyVisionRecord() {
        // dvvC: version 1.0, profile 8, level 6, rpu 1, el 0, bl 1, compatibility 1.
        let dvvC: [UInt8] = [0, 0, 0, 32] + Array("dvvC".utf8) + [1, 0, 8 << 1 | 0, 6 << 3 | 0b101, 1 << 4] + Array(repeating: 0, count: 19)
        let data = Data([0, 0, 0, 8] + Array("hvc1".utf8) + Array(repeating: 0, count: 8) + dvvC)
        #expect(InitSegmentBuilder.describeVideo(data) == "hvc1, dvvC version 1.0 profile 8 level 6 rpu 1 el 0 bl 1 compatibility 1")
        #expect(InitSegmentBuilder.describeVideo(Data(Array("hvc1".utf8))) == "hvc1, no dvcC/dvvC")
    }
}
