import CoreGraphics
import Foundation
import Testing
@testable import EnhancedNativePlayer

struct ExternalSubtitleTests {
    private func seconds(_ value: Double) -> Int64 { Int64((value * 10_000_000).rounded()) }

    // MARK: Timing

    @Test func timestampsInEveryShape() {
        #expect(ExternalSubtitleParser.timestamp("01:02:03,456") == seconds(3723.456))
        #expect(ExternalSubtitleParser.timestamp("01:02:03.456") == seconds(3723.456))
        #expect(ExternalSubtitleParser.timestamp("02:03.456") == seconds(123.456))
        #expect(ExternalSubtitleParser.timestamp("0:00:01.50") == seconds(1.5))
        #expect(ExternalSubtitleParser.timestamp("00:00:05") == seconds(5))
        #expect(ExternalSubtitleParser.timestamp("00:00:61,000") == nil)
        #expect(ExternalSubtitleParser.timestamp("aa:00:01,000") == nil)
        #expect(ExternalSubtitleParser.timestamp("1") == nil)
    }

    @Test func timingLineKeepsWebVTTSettings() throws {
        let timing = try #require(ExternalSubtitleParser.timing("00:01.000 --> 00:02.500 line:10% align:start"))
        #expect(timing.start == seconds(1))
        #expect(timing.end == seconds(2.5))
        #expect(timing.settings == "line:10% align:start")
    }

    // MARK: SRT

    @Test func subRipCuesWithTagsAndOverrides() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>Hello</i> & {\\an8}<font color=\"red\">world</font>\r\nSecond line\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nNext\r\n"
        let cues = ExternalSubtitleParser.parseSubRip(srt)
        #expect(cues.count == 2)
        #expect(cues[0].startTicks == seconds(1))
        #expect(cues[0].endTicks == seconds(2.5))
        #expect(cues[0].text == "<i>Hello</i> &amp; world\nSecond line")
        #expect(cues[1].text == "Next")
    }

    @Test func subRipWithoutBlankLinesBetweenCues() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nOne\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n"
        let cues = ExternalSubtitleParser.parseSubRip(srt)
        #expect(cues.map(\.text) == ["One", "Two"])
    }

    @Test func subRipSkipsEmptyAndBackwardsCues() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n\n2\n00:00:05,000 --> 00:00:04,000\nBackwards\n\n3\n00:00:06,000 --> 00:00:07,000\nKept\n"
        #expect(ExternalSubtitleParser.parseSubRip(srt).map(\.text) == ["Kept"])
    }

    @Test func decodesByteOrderMarksAndWindows1252() {
        #expect(ExternalSubtitleParser.decode(Data([0xEF, 0xBB, 0xBF] + Array("Café".utf8))) == "Café")
        #expect(ExternalSubtitleParser.decode(Data([0xFF, 0xFE]) + "Café".data(using: .utf16LittleEndian)!) == "Café")
        #expect(ExternalSubtitleParser.decode(Data([0x43, 0x61, 0x66, 0xE9])) == "Café")
    }

    // MARK: WebVTT

    @Test func webVTTCuesWithIdentifiersNotesAndSettings() {
        let vtt = """
        WEBVTT
        Kind: captions

        NOTE this is a comment
        spanning lines

        intro
        00:01.000 --> 00:02.000 align:start
        Hi & <b>there</b>

        00:00:03.000 --> 00:00:04.000
        Bye
        """
        let cues = ExternalSubtitleParser.parseWebVTT(vtt)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Hi &amp; <b>there</b>")
        #expect(cues[0].settings == "align:start")
        #expect(cues[0].startTicks == seconds(1))
        #expect(cues[1].settings == nil)
    }

    // MARK: ASS

    private let script = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,72,&H000000FF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,2,10,10,40,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Comment: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,ignored
    Dialogue: 1,0:00:03.00,0:00:04.00,Default,Bob,0,0,0,,Later, with a comma
    Dialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\b1}First{\\b0}
    """

    @Test func assSplitsIntoHeaderAndMatroskaBlocks() {
        let (header, events) = ExternalSubtitleParser.parseASS(script)
        let headerText = String(decoding: header, as: UTF8.self)
        #expect(headerText.contains("[V4+ Styles]"))
        #expect(headerText.contains("Format: Layer, Start, End"))
        #expect(!headerText.contains("Dialogue"))
        #expect(!headerText.contains("Comment"))
        #expect(events.count == 2)
        // Sorted by start; ReadOrder is the line's place in the script.
        #expect(events[0].startTicks == seconds(1))
        #expect(events[0].endTicks == seconds(2.5))
        #expect(String(decoding: events[0].data, as: UTF8.self) == "1,0,Default,,0,0,0,,{\\b1}First{\\b0}")
        #expect(String(decoding: events[1].data, as: UTF8.self) == "0,1,Default,Bob,0,0,0,,Later, with a comma")
    }

    @Test func assEventsDrawThroughLibass() throws {
        let (header, events) = ExternalSubtitleParser.parseASS(script)
        let renderer = try #require(LibassRenderer(header: header, fonts: [], videoMatrix: .bt709))
        renderer.set(layout: .init(frameWidth: 1920, frameHeight: 1080, video: CGRect(x: 0, y: 0, width: 1920, height: 1080), storageWidth: 1920, storageHeight: 1080))
        renderer.add(events.map { event in
            let start = ASSTime.milliseconds(ticks: event.startTicks)
            return ASSEvent(startMilliseconds: start, durationMilliseconds: ASSTime.milliseconds(ticks: event.endTicks) - start, data: event.data)
        })
        #expect(renderer.render(atMilliseconds: 999).image == nil)
        #expect(renderer.render(atMilliseconds: 1000).image != nil)
        #expect(renderer.render(atMilliseconds: 2600).image == nil)
        #expect(renderer.render(atMilliseconds: 3500).image != nil)
    }

    @Test func assWithoutFormatLineGetsTheDefault() {
        let (header, events) = ExternalSubtitleParser.parseASS("[Script Info]\nScriptType: v4.00+\n\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hi\n")
        #expect(String(decoding: header, as: UTF8.self).contains("Format: Layer, Start, End, Style"))
        #expect(events.count == 1)
    }

    // MARK: Format

    @Test func formatFromExtensionOrContent() {
        #expect(ExternalSubtitleParser.format(of: "", fileExtension: "SRT") == .subRip)
        #expect(ExternalSubtitleParser.format(of: "WEBVTT\n", fileExtension: "") == .webVTT)
        #expect(ExternalSubtitleParser.format(of: "\n[Script Info]\n", fileExtension: "txt") == .ass)
        #expect(ExternalSubtitleParser.format(of: "1\n00:00:01,000 --> 00:00:02,000\nHi\n", fileExtension: "sub") == .subRip)
        #expect(ExternalSubtitleParser.format(of: "<?xml version=\"1.0\"?>", fileExtension: "ttml") == nil)
    }

    @Test func unsupportedFileIsRejected() {
        let url = URL(string: "https://example.com/subs.sup")!
        #expect(throws: EnhancedPlayerError.self) {
            try ExternalSubtitleParser.parse(Data([0x50, 0x47, 0x00, 0x01]), fileExtension: "sup", url: url)
        }
    }

    // MARK: Chapters

    @Test func chapterEndsComeFromTheNextChapter() {
        let chapters = [
            Chapter(title: "B", start: 100),
            Chapter(title: "A", start: 0),
            Chapter(title: "C", start: 200, end: 250),
        ]
        let resolved = chapters.resolvingEnds(movieEnd: 300)
        #expect(resolved.map(\.chapter.title) == ["A", "B", "C"])
        #expect(resolved.map(\.end) == [100, 200, 250])
        #expect([Chapter(title: "Last", start: 10)].resolvingEnds(movieEnd: 60).map(\.end) == [60])
    }
}

/// The master and subtitle playlists with external tracks and a chosen start.
struct StartSelectionPlaylistTests {
    private func media(subtitles: [SubtitleTrack]) -> MediaInfo {
        let ms = Rational(num: 1, den: 1000)
        let video = VideoTrack(
            streamIndex: 0, codec: .h264, timeBase: ms, width: 1920, height: 1080, frameRate: 24,
            frameDuration: 42, reorderDepth: 0, bitRate: nil, range: .sdr, dolbyVision: nil,
            extradata: [], profile: 100, level: 40
        )
        func audio(_ index: Int, language: String, isDefault: Bool) -> AudioTrack {
            AudioTrack(
                index: index, streamIndex: Int32(index + 1), codecID: 0, codecName: "aac", profile: 0, profileName: nil,
                timeBase: ms, startTime: 0, sampleRate: 48000, channels: 2, bitsPerRawSample: 0, language: language,
                title: nil, bitRate: nil, isDefault: isDefault, isAtmos: false, delivery: .copy, extradata: []
            )
        }
        return MediaInfo(
            formatName: "matroska", fileSize: 1_000_000, durationSeconds: 25, bitRate: nil, video: video,
            audio: [audio(0, language: "eng", isDefault: true), audio(1, language: "jpn", isDefault: false)],
            subtitles: subtitles,
            keyframes: KeyframeIndex(timestamps: [0, 6000, 12000, 18000], positions: [0, 1, 2, 3], timeBase: ms, usesDecodeTimestamps: false, presentationOffset: 0),
            videoEndTimestamp: 25000
        )
    }

    private func subtitle(_ index: Int, language: String, isDefault: Bool = false, external: ExternalSubtitleContent? = nil) -> SubtitleTrack {
        SubtitleTrack(
            index: index, streamIndex: external == nil ? Int32(index + 10) : -1, codecName: "subrip", timeBase: .ticks,
            language: language, title: nil, isDefault: isDefault, isForced: false, textFormat: external == nil ? .subRip : nil,
            external: external
        )
    }

    private func builder(_ media: MediaInfo) -> PlaylistBuilder {
        let plan = SegmentPlan(keyframes: media.keyframes.timestamps, timeBase: media.keyframes.timeBase, hlsTime: 6, end: media.videoEndTimestamp)
        return PlaylistBuilder(media: media, plan: plan, subtitleGrid: SubtitleGrid(totalTicks: 250_000_000))
    }

    private func defaults(_ master: String, type: String) -> [String] {
        master.split(separator: "\n").filter { $0.contains("TYPE=\(type)") && $0.contains("DEFAULT=YES") }.map {
            String($0.split(separator: ",").first { $0.hasPrefix("NAME=") }!.dropFirst(5))
        }
    }

    @Test func externalTrackIsOneSegmentAsLongAsTheMovie() {
        let playlists = builder(media(subtitles: [
            subtitle(0, language: "en", external: .text([])),
            subtitle(1, language: "eng"),
        ]))
        let external = playlists.subtitlePlaylist(track: 0)
        #expect(external.contains("#EXT-X-TARGETDURATION:25\n"))
        #expect(external.components(separatedBy: "#EXTINF:").count == 2)
        #expect(external.contains("#EXTINF:25.000000,\nsubtitle_0_0.vtt"))
        #expect(playlists.subtitlePlaylist(track: 1).components(separatedBy: "#EXTINF:").count == 4)
        // External first: the file's English track is the second English one.
        #expect(playlists.subtitleNames() == ["English", "English (2)"])
    }

    @Test func chosenTracksAreTheDefaults() {
        let playlists = builder(media(subtitles: [
            subtitle(0, language: "en", external: .text([])),
            subtitle(1, language: "eng", isDefault: true),
            subtitle(2, language: "fre"),
        ]))
        #expect(defaults(playlists.master(), type: "AUDIO") == ["\"English - AAC\""])
        #expect(defaults(playlists.master(), type: "SUBTITLES") == ["\"English (2)\""])

        let chosen = StartSelection(audio: 1, subtitle: .track(2))
        #expect(defaults(playlists.master(start: chosen), type: "AUDIO") == ["\"Japanese - AAC\""])
        #expect(defaults(playlists.master(start: chosen), type: "SUBTITLES") == ["\"French\""])
        #expect(defaults(playlists.master(start: StartSelection(subtitle: .off)), type: "SUBTITLES").isEmpty)
        #expect(defaults(playlists.master(start: StartSelection(subtitle: .track(0))), type: "SUBTITLES") == ["\"English\""])
        // An index that doesn't exist falls back to the file's default.
        #expect(playlists.defaultAudioIndex(StartSelection(audio: 7)) == 0)
    }

    @Test func externalTracksDontChangeTheFilesDefaultRule() {
        // Matroska flags every track default unless a muxer clears it: then nobody chose one.
        let playlists = builder(media(subtitles: [
            subtitle(0, language: "en", external: .text([])),
            subtitle(1, language: "eng", isDefault: true),
            subtitle(2, language: "fre", isDefault: true),
        ]))
        #expect(playlists.defaultSubtitleIndex() == nil)
    }
}

/// Opt-in, like `EndToEndTests`: external files next to a real movie.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ENP_E2E_URL"] != nil))
struct ExternalSubtitleSessionTests {
    let source = URL(string: ProcessInfo.processInfo.environment["ENP_E2E_URL"] ?? "http://invalid")!

    @Test func externalTracksComeFirstAndServeWhole() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let srt = directory.appendingPathComponent("movie.en.srt")
        try "1\n00:00:05,000 --> 00:00:07,000\nExternal hello\n".write(to: srt, atomically: true, encoding: .utf8)
        let ass = directory.appendingPathComponent("movie.ja.ass")
        try "[Script Info]\nScriptType: v4.00+\n\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hi\n".write(to: ass, atomically: true, encoding: .utf8)
        let missing = directory.appendingPathComponent("missing.srt")

        let plain = try await EnhancedPlaybackSession.start(url: source)
        let embedded = plain.subtitleTrackNames.count
        await plain.stop()

        let session = try await EnhancedPlaybackSession.start(url: source, externalSubtitles: [
            ExternalSubtitle(url: srt, language: "en"),
            ExternalSubtitle(url: missing, language: "de"),
            ExternalSubtitle(url: ass, language: "ja"),
        ])
        defer { Task { await session.stop() } }
        // The missing file is left out; the other two come before the file's own tracks.
        #expect(session.subtitleTrackNames.count == embedded + 2)
        #expect(session.subtitleTrackNames[0] == "English")
        #expect(session.subtitleTrackNames[1] == "Japanese")
        #expect(session.assTrack(named: "Japanese") == 1)

        let base = session.masterPlaylistURL.deletingLastPathComponent()
        let playlist = String(decoding: try await URLSession.shared.data(from: base.appendingPathComponent("subtitle_0.m3u8")).0, as: UTF8.self)
        #expect(playlist.components(separatedBy: "#EXTINF:").count == 2)
        let vtt = String(decoding: try await URLSession.shared.data(from: base.appendingPathComponent("subtitle_0_0.vtt")).0, as: UTF8.self)
        let start = 5 - session.originSeconds
        #expect(vtt.contains(WebVTT.timestamp(Int64((start * 10_000_000).rounded())) + " --> "))
        #expect(vtt.contains("External hello"))

        let assEvents = try await session.assSegment(track: 1, segment: 0)
        #expect(assEvents.events.count == 1)
    }
}
