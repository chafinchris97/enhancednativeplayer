import Foundation

/// Builds `master.m3u8`, `video.m3u8`, `audio_{n}.m3u8` and `subtitle_{n}.m3u8` from the
/// probe and the plan, plus `master_sdr.m3u8` and `video_sdr.m3u8` for the relabeled video of an HDR file.
struct PlaylistBuilder: Sendable {
    let media: MediaInfo
    let plan: SegmentPlan
    let subtitleGrid: SubtitleGrid
    /// The thumbnails behind `iframe.m3u8`, nil when the session has none.
    var trickplay: TrickplayRendition?

    static let audioGroup = "audio"
    static let subtitleGroup = "subtitles"

    // MARK: Master

    /// The audio track the player starts on: the one asked for, else the container's default, else the first.
    func defaultAudioIndex(_ start: StartSelection = StartSelection()) -> Int? {
        if let audio = start.audio, media.audio.indices.contains(audio) { return audio }
        return media.audio.first(where: \.isDefault)?.index ?? media.audio.first?.index
    }

    /// The regular (non-forced) subtitle track in the first of `preferredLanguages` (BCP 47, as
    /// in `Locale.preferredLanguages`) the file has one in. Nil when the audio track at `audio`
    /// is already in the language reached first, or when no track matches.
    func preferredSubtitleIndex(forAudio audio: Int?, preferredLanguages: [String]) -> Int? {
        let audioLanguage = audio.flatMap { media.audio.indices.contains($0) ? media.audio[$0].language : nil }.flatMap(Languages.tag)
        for preferred in preferredLanguages {
            guard let tag = Languages.tag(Locale.Language(identifier: preferred).languageCode?.identifier ?? preferred) else { continue }
            if tag == audioLanguage { return nil }
            if let track = media.subtitles.first(where: { !$0.isForced && $0.language.flatMap(Languages.tag) == tag }) {
                return track.index
            }
        }
        return nil
    }

    /// The subtitle track the master marks DEFAULT, nil for none.
    func defaultSubtitleIndex(_ start: StartSelection = StartSelection()) -> Int? {
        switch start.subtitle {
        case .off: return nil
        case .track(let index) where media.subtitles.indices.contains(index): return index
        default: break
        }
        // Matroska's default flag is on unless a muxer clears it, so when every track
        // carries it nobody chose one and subtitles start off. External tracks carry no flag.
        // Forced tracks are never the default: they turn on with their audio's language instead.
        let embedded = media.subtitles.filter { !$0.isExternal && !$0.isForced }
        let flaggedDefault = embedded.filter(\.isDefault)
        return flaggedDefault.count == embedded.count && embedded.count > 1 ? nil : flaggedDefault.first?.index
    }

    func master(sdr: Bool = false, start: StartSelection = StartSelection()) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS", ""]
        let names = audioNames()
        for track in media.audio {
            // AVFoundation's displayName (what AVPlayerViewController's audio menu shows) is the
            // NAME only for a rendition with no LANGUAGE and neither AUTOSELECT nor DEFAULT.
            // With either of those it is built from LANGUAGE alone, "Unknown" without one. With
            // no AUTOSELECT or DEFAULT, AVPlayer starts on no audio, so the player selects it.
            // Without LANGUAGE, AVPlayer offers subtitles generated from the audio as well.
            var attributes = [
                "TYPE=AUDIO",
                "GROUP-ID=\"\(Self.audioGroup)\"",
                "NAME=\"\(names[track.index])\"",
            ]
            attributes.append("CHANNELS=\"\(track.isAtmos && track.delivery == .copy ? "16/JOC" : String(track.deliveredChannels))\"")
            attributes.append("URI=\"audio_\(track.index).m3u8\"")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        if !media.audio.isEmpty { lines.append("") }

        let subtitleNames = subtitleNames()
        let subtitleLanguages = subtitleLanguages()
        let defaultSubtitle = defaultSubtitleIndex(start)
        for track in media.subtitles {
            var attributes = [
                "TYPE=SUBTITLES",
                "GROUP-ID=\"\(Self.subtitleGroup)\"",
                "NAME=\"\(subtitleNames[track.index])\"",
                "LANGUAGE=\"\(subtitleLanguages[track.index])\"",
            ]
            // AVPlayer turns a DEFAULT rendition on only if it may also autoselect it. The
            // others stay out of automatic selection.
            if track.index == defaultSubtitle {
                attributes += ["AUTOSELECT=YES", "DEFAULT=YES"]
            } else {
                attributes.append("DEFAULT=NO")
            }
            attributes.append("URI=\"subtitle_\(track.index).m3u8\"")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        if !media.subtitles.isEmpty { lines.append("") }

        let video = sdr ? media.video.sdrVariant : media.video
        let audioCodecs = uniqued(media.audio.map(CodecStrings.audio))
        let (peak, average) = bandwidth()

        // Dolby Vision profile 8 is one variant: CODECS is the HEVC base layer and
        // SUPPLEMENTAL-CODECS the Dolby Vision on top, which a client without it ignores.
        var attributes = [
            "BANDWIDTH=\(peak)",
            "AVERAGE-BANDWIDTH=\(average)",
            "CODECS=\"\(([CodecStrings.video(video)] + audioCodecs).joined(separator: ","))\"",
        ]
        if let supplemental = CodecStrings.supplemental(video) {
            attributes.append("SUPPLEMENTAL-CODECS=\"\(supplemental)\"")
        }
        attributes.append("RESOLUTION=\(video.width)x\(video.height)")
        if let rate = video.frameRate { attributes.append("FRAME-RATE=\(String(format: "%.3f", rate))") }
        attributes.append("VIDEO-RANGE=\(video.range.rawValue)")
        if !media.audio.isEmpty { attributes.append("AUDIO=\"\(Self.audioGroup)\"") }
        if !media.subtitles.isEmpty { attributes.append("SUBTITLES=\"\(Self.subtitleGroup)\"") }
        attributes.append("CLOSED-CAPTIONS=NONE")
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append(sdr ? "video_sdr.m3u8" : "video.m3u8")
        if let trickplay {
            let attributes = [
                "BANDWIDTH=\(trickplay.bandwidth)",
                "AVERAGE-BANDWIDTH=\(trickplay.averageBandwidth)",
                "CODECS=\"mjpg\"",
                "RESOLUTION=\(trickplay.trickplay.width)x\(trickplay.trickplay.height)",
                "VIDEO-RANGE=SDR",
                "URI=\"iframe.m3u8\"",
            ]
            lines.append("#EXT-X-I-FRAME-STREAM-INF:" + attributes.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One JPEG still per second of the playlist timeline, each its own fragment.
    func iFramePlaylist() -> String? {
        guard let trickplay else { return nil }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:1",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-I-FRAMES-ONLY",
            "#EXT-X-MAP:URI=\"init_iframe.mp4\"",
        ]
        for index in 0..<trickplay.entryCount {
            lines.append(String(format: "#EXTINF:%f,", trickplay.entryDuration(index)))
            lines.append("iframe_\(index).mp4")
        }
        lines.append("#EXT-X-ENDLIST")
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

    /// Subtitles have their own fixed 10 s segments, independent of the video cuts. An external
    /// track is already whole in memory, so it is one segment as long as the movie.
    func subtitlePlaylist(track: Int) -> String {
        let external = media.subtitles[track].isExternal
        let total = Double(subtitleGrid.totalTicks) / 10_000_000
        let targetDuration = external ? max(1, Int(total.rounded(.up))) : Int(SubtitleGrid.segmentTicks / 10_000_000)
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        if external {
            lines.append(String(format: "#EXTINF:%f,", total))
            lines.append("subtitle_\(track)_0.vtt")
        } else {
            for index in 0..<subtitleGrid.count {
                lines.append(String(format: "#EXTINF:%f,", subtitleGrid.duration(of: index)))
                lines.append("subtitle_\(track)_\(index).vtt")
            }
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
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
        uniqueNames(media.audio.map { ($0.language, $0.title, codecLabel($0)) })
    }

    /// `{Language}`, then `{Language} ({n})` for later tracks of the same language, n counting
    /// its non-forced tracks. Forced tracks are `{Language} (Forced)` on their own count. Unique, as HLS requires.
    func subtitleNames() -> [String] {
        var counts: [String: Int] = [:]
        return media.subtitles.map { track in
            let language = track.language.flatMap(Languages.displayName) ?? "Unknown"
            let base = track.isForced ? "\(language) (Forced)" : language
            let count = counts[base, default: 0] + 1
            counts[base] = count
            return count == 1 ? base : "\(base) (\(count))"
        }
    }

    /// LANGUAGE for each subtitle track. The first non-forced track of a language gets the real tag
    /// so the menu and the system's language preference see the language. The menu labels an option
    /// from LANGUAGE alone, so forced tracks, later tracks of the same language, and a track with no
    /// known language carry their NAME instead to stay apart. No rendition is marked FORCED: AVPlayer
    /// would only show one when the audio's LANGUAGE matched, and the audio renditions carry none.
    func subtitleLanguages() -> [String] {
        let names = subtitleNames()
        var taken = Set<String>()
        return media.subtitles.map { track in
            guard !track.isForced, let tag = track.language.flatMap(Languages.tag) else { return names[track.index] }
            return taken.insert(tag).inserted ? tag : names[track.index]
        }
    }

    private func uniqueNames(_ tracks: [(language: String?, title: String?, codec: String)]) -> [String] {
        var seen: [String: Int] = [:]
        return tracks.map { track in
            var parts = [track.language.flatMap(Languages.displayName) ?? "Unknown"]
            if let title = track.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                parts.append(title)
            }
            parts.append(track.codec)
            var name = parts.joined(separator: " - ").replacingOccurrences(of: "\"", with: "'")
            let count = seen[name, default: 0]
            seen[name] = count + 1
            if count > 0 { name += " (\(count + 1))" }
            return name
        }
    }

    func codecLabel(_ track: AudioTrack) -> String {
        // A FLAC transcode is lossless, so the label names the source codec.
        if track.delivery == .flac {
            return track.profileName ?? track.codecName.uppercased()
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

/// Which tracks playback starts with, when the app chose them.
struct StartSelection: Sendable, Equatable {
    enum Subtitle: Sendable, Equatable {
        case off
        case track(Int)
    }

    var audio: Int?
    /// Nil: the file's default.
    var subtitle: Subtitle?
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

    /// The BCP 47 tag for a Matroska / MP4 code: the two-letter form when there is one ("eng" → "en").
    static func tag(_ code: String) -> String? {
        let language = Locale.LanguageCode(normalized(code))
        guard language.isISOLanguage else { return nil }
        return language.identifier(.alpha2) ?? language.identifier
    }

    static func displayName(_ code: String) -> String? {
        let english = Locale(identifier: "en_US")
        return english.localizedString(forIdentifier: normalized(code)) ?? english.localizedString(forLanguageCode: normalized(code))
    }
}
