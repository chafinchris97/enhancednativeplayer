import Foundation

/// Builds `master.m3u8`, `video.m3u8` and `audio_{n}.m3u8` from the probe and the plan,
/// plus `master_sdr.m3u8` and `video_sdr.m3u8` for the relabeled video of an HDR file.
struct PlaylistBuilder: Sendable {
    let media: MediaInfo
    let plan: SegmentPlan

    static let audioGroup = "audio"

    // MARK: Master

    func master(sdr: Bool = false) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS", ""]
        let names = audioNames()
        let defaultTrack = media.audio.first(where: \.isDefault)?.index ?? media.audio.first?.index
        for track in media.audio {
            // AVFoundation builds an option's displayName (what AVPlayerViewController's
            // audio menu shows) from LANGUAGE and ignores NAME, so the label goes in both.
            // It is not a BCP 47 tag; DEFAULT, not language preference, picks the track.
            var attributes = [
                "TYPE=AUDIO",
                "GROUP-ID=\"\(Self.audioGroup)\"",
                "NAME=\"\(names[track.index])\"",
                "LANGUAGE=\"\(names[track.index])\"",
            ]
            attributes.append("AUTOSELECT=YES")
            attributes.append("DEFAULT=\(track.index == defaultTrack ? "YES" : "NO")")
            attributes.append("CHANNELS=\"\(track.isAtmos && track.delivery == .copy ? "16/JOC" : String(track.deliveredChannels))\"")
            attributes.append("URI=\"audio_\(track.index).m3u8\"")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        if !media.audio.isEmpty { lines.append("") }

        let video = sdr ? media.video.sdrVariant : media.video
        let audioCodecs = uniqued(media.audio.map(CodecStrings.audio))
        let (peak, average) = bandwidth()

        func variant(codec: String, range: VideoRange) {
            var attributes = [
                "BANDWIDTH=\(peak)",
                "AVERAGE-BANDWIDTH=\(average)",
                "CODECS=\"\(([codec] + audioCodecs).joined(separator: ","))\"",
                "RESOLUTION=\(video.width)x\(video.height)",
            ]
            if let rate = video.frameRate { attributes.append("FRAME-RATE=\(String(format: "%.3f", rate))") }
            attributes.append("VIDEO-RANGE=\(range.rawValue)")
            if !media.audio.isEmpty { attributes.append("AUDIO=\"\(Self.audioGroup)\"") }
            attributes.append("CLOSED-CAPTIONS=NONE")
            lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
            lines.append(sdr ? "video_sdr.m3u8" : "video.m3u8")
        }

        variant(codec: CodecStrings.video(video), range: video.range)
        // Profile 8 carries an HDR10 / HLG / SDR base layer: offer it as a fallback
        // variant for clients that pass on Dolby Vision. Profile 5 has no compatible
        // base layer, and profile 7 is already announced as plain HEVC HDR.
        if video.emitsDolbyVision, let dv = video.dolbyVision, dv.profile == 8 {
            variant(codec: CodecStrings.baseLayer(video), range: video.range)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Media playlists

    func videoPlaylist() -> String {
        mediaPlaylist(map: "init_video.mp4") { "video_\($0).mp4" }
    }

    func sdrVideoPlaylist() -> String {
        mediaPlaylist(map: "init_video_sdr.mp4") { "video_sdr_\($0).mp4" }
    }

    func audioPlaylist(track: Int) -> String {
        mediaPlaylist(map: "audio_\(track)_init.mp4") { "audio_\(track)_\($0).mp4" }
    }

    /// Audio segments use the video cuts, so both playlists share every EXTINF.
    private func mediaPlaylist(map: String, segmentName: (Int) -> String) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(plan.targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"\(map)\"",
        ]
        for segment in plan.segments {
            lines.append(String(format: "#EXTINF:%f,", segment.duration))
            lines.append("\(segmentName(segment.index))?runtimeTicks=\(segment.runtimeTicks)")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Labels

    /// `{Language} - {Track Title} - {Codec}`, unique within the group as HLS requires.
    func audioNames() -> [String] {
        var seen: [String: Int] = [:]
        return media.audio.map { track in
            var parts = [track.language.flatMap(Languages.displayName) ?? "Unknown"]
            if let title = track.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                parts.append(title)
            }
            parts.append(codecLabel(track))
            var name = parts.joined(separator: " - ").replacingOccurrences(of: "\"", with: "'")
            let count = seen[name, default: 0]
            seen[name] = count + 1
            if count > 0 { name += " (\(count + 1))" }
            return name
        }
    }

    func codecLabel(_ track: AudioTrack) -> String {
        if track.delivery == .flac {
            let source = track.profileName ?? track.codecName.uppercased()
            return "FLAC (\(source))"
        }
        switch track.codecName {
        case "aac": return "AAC"
        case "ac3": return "AC3"
        case "eac3": return track.isAtmos ? "EAC3 Atmos" : "EAC3"
        case "flac": return "FLAC"
        default: return track.codecName.uppercased()
        }
    }

    // MARK: Bandwidth

    /// Peak and average bits per second. The peak comes from the byte span between
    /// consecutive segment starts in the container index, which covers every
    /// interleaved track, and skips segments under half a second as hlsenc does.
    func bandwidth() -> (peak: Int, average: Int) {
        let duration = max(media.durationSeconds, plan.timeBase.seconds(media.videoEndTimestamp - plan.origin))
        let average = duration > 0 ? Int(Double(media.fileSize) * 8 / duration) : Int(media.bitRate ?? 0)
        var positions: [Int64: Int64] = [:]
        for (ts, pos) in zip(media.keyframes.timestamps, media.keyframes.positions) where pos >= 0 {
            positions[ts] = pos
        }
        var peak = 0
        for (i, segment) in plan.segments.enumerated() where segment.duration >= 0.5 {
            guard let start = positions[segment.start] else { continue }
            let end = i + 1 < plan.count ? positions[plan.segments[i + 1].start] : media.fileSize
            guard let end, end > start else { continue }
            peak = max(peak, Int(Double(end - start) * 8 / segment.duration))
        }
        if peak < average { peak = Int(Double(average) * 1.5) }
        return (max(peak, 1), max(average, 1))
    }

    private func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum Languages {
    /// ISO 639-2/B codes Matroska often carries, mapped to the /T form Foundation knows.
    private static let bibliographic: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces",
        "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
        "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas", "rum": "ron", "slo": "slk",
        "tib": "bod", "wel": "cym",
    ]

    private static func normalized(_ code: String) -> String {
        let lower = code.lowercased()
        return bibliographic[lower] ?? lower
    }

    static func displayName(_ code: String) -> String? {
        let english = Locale(identifier: "en_US")
        return english.localizedString(forIdentifier: normalized(code)) ?? english.localizedString(forLanguageCode: normalized(code))
    }
}
