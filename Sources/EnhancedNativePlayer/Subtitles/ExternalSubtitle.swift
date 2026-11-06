import Foundation

/// A subtitle file that sits next to the video instead of inside it: SRT, WebVTT or ASS / SSA.
///
/// External tracks come first in the subtitle menu, in the order they were passed, before
/// the file's own tracks. Subtitle indices count them first too. A file that can't be fetched or
/// read is left out and logged; playback goes ahead without it.
public struct ExternalSubtitle: Hashable, Sendable {
    public var url: URL
    /// ISO 639-1 / 639-2 code or BCP 47 tag, e.g. "en", "eng" or "pt-BR".
    public var language: String
    public var isForced: Bool
    /// Fonts an ASS script needs that aren't installed on the device. Ignored for SRT and WebVTT.
    public var fonts: [URL]

    public init(url: URL, language: String, isForced: Bool = false, fonts: [URL] = []) {
        self.url = url
        self.language = language
        self.isForced = isForced
        self.fonts = fonts
    }
}

/// What an external file holds, in the source file's timeline (100 ns ticks).
enum ExternalSubtitleContent: Sendable, Equatable {
    case text([SubtitleCue])
    case ass(header: [UInt8], events: [ExternalASSEvent])
}

struct ExternalASSEvent: Sendable, Equatable {
    var startTicks: Int64
    var endTicks: Int64
    /// `ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text`, the form
    /// Matroska stores and `ass_process_chunk` takes.
    var data: [UInt8]
}

/// An external subtitle once fetched and parsed.
struct LoadedExternalSubtitle: Sendable {
    var subtitle: ExternalSubtitle
    var content: ExternalSubtitleContent
    var fonts: [ASSFont]
}

enum ExternalSubtitleLoader {
    static let maxBytes = 10 << 20

    static func load(_ subtitle: ExternalSubtitle, headers: [String: String]) async throws -> LoadedExternalSubtitle {
        let data = try await fetch(subtitle.url, headers: headers)
        let content = try ExternalSubtitleParser.parse(data, fileExtension: subtitle.url.pathExtension, url: subtitle.url)
        var fonts: [ASSFont] = []
        if case .ass = content {
            for url in subtitle.fonts {
                fonts.append(ASSFont(name: url.lastPathComponent, data: Array(try await fetch(url, headers: headers))))
            }
        }
        return LoadedExternalSubtitle(subtitle: subtitle, content: content, fonts: fonts)
    }

    private static func fetch(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EnhancedPlayerError.http(status: http.statusCode, url: url)
        }
        guard data.count <= maxBytes else { throw EnhancedPlayerError.subtitleTooLarge(url) }
        return data
    }
}

enum ExternalSubtitleParser {
    enum Format: Equatable {
        case subRip
        case webVTT
        case ass
    }

    static func parse(_ data: Data, fileExtension: String, url: URL) throws -> ExternalSubtitleContent {
        let text = decode(data)
        guard let format = format(of: text, fileExtension: fileExtension) else {
            throw EnhancedPlayerError.unsupportedSubtitleFormat(url)
        }
        switch format {
        case .subRip: return .text(parseSubRip(text))
        case .webVTT: return .text(parseWebVTT(text))
        case .ass:
            let (header, events) = parseASS(text)
            return .ass(header: header, events: events)
        }
    }

    /// By extension, or by the first line when the extension says nothing.
    static func format(of text: String, fileExtension: String) -> Format? {
        switch fileExtension.lowercased() {
        case "srt": return .subRip
        case "vtt", "webvtt": return .webVTT
        case "ass", "ssa": return .ass
        default: break
        }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        if first.hasPrefix("WEBVTT") { return .webVTT }
        if first.lowercased() == "[script info]" { return .ass }
        if lines.prefix(3).contains(where: { timing($0) != nil }) { return .subRip }
        return nil
    }

    /// UTF-8 or UTF-16 by their byte order mark, then UTF-8, then Windows-1252, which older SRTs often are.
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian) ?? "" }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) ?? "" }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    // MARK: SRT

    static func parseSubRip(_ text: String) -> [SubtitleCue] {
        let lines = lines(text)
        var cues: [SubtitleCue] = []
        var i = 0
        while i < lines.count {
            guard let (start, end, _) = timing(lines[i]) else {
                i += 1
                continue
            }
            i += 1
            var body: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, timing(lines[i]) == nil {
                // Files missing the blank line: a cue number right before the next timing line.
                if i + 1 < lines.count, Int(lines[i].trimmingCharacters(in: .whitespaces)) != nil, timing(lines[i + 1]) != nil { break }
                body.append(lines[i])
                i += 1
            }
            guard end > start, let cueText = WebVTT.cueText(payload: Array(body.joined(separator: "\n").utf8), format: .subRip) else { continue }
            cues.append(SubtitleCue(startTicks: start, endTicks: end, text: cueText))
        }
        return cues.sorted { $0.startTicks < $1.startTicks }
    }

    // MARK: WebVTT

    static func parseWebVTT(_ text: String) -> [SubtitleCue] {
        var blocks: [[String]] = [[]]
        for line in lines(text) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !blocks[blocks.count - 1].isEmpty { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        var cues: [SubtitleCue] = []
        // The first block is the WEBVTT header.
        for block in blocks.dropFirst() {
            guard let first = block.first, !first.hasPrefix("NOTE"), !first.hasPrefix("STYLE"), !first.hasPrefix("REGION") else { continue }
            // An optional identifier comes before the timing line.
            guard let timingIndex = block.prefix(2).firstIndex(where: { $0.contains("-->") }),
                  let (start, end, settings) = timing(block[timingIndex]),
                  end > start,
                  let cueText = WebVTT.cueText(payload: Array(block[(timingIndex + 1)...].joined(separator: "\n").utf8), format: .webVTT)
            else { continue }
            cues.append(SubtitleCue(startTicks: start, endTicks: end, text: cueText, settings: settings))
        }
        return cues.sorted { $0.startTicks < $1.startTicks }
    }

    // MARK: ASS

    private static let defaultEventFormat = ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]

    /// Splits a script into what libass takes as codec private data, everything but the events,
    /// and its `Dialogue` lines in Matroska's block form. ReadOrder is the line's place among them.
    static func parseASS(_ text: String) -> (header: [UInt8], events: [ExternalASSEvent]) {
        var header: [String] = []
        var events: [ExternalASSEvent] = []
        var inEvents = false
        var sawEvents = false
        var format: [String]?
        for line in lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                if inEvents, format == nil {
                    header.append("Format: " + defaultEventFormat.joined(separator: ", "))
                    format = defaultEventFormat
                }
                inEvents = trimmed.lowercased() == "[events]"
                sawEvents = sawEvents || inEvents
                header.append(line)
                continue
            }
            guard inEvents else {
                header.append(line)
                continue
            }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("format:") {
                format = trimmed.dropFirst("format:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                header.append(line)
            } else if lower.hasPrefix("dialogue:") {
                if format == nil {
                    header.append("Format: " + defaultEventFormat.joined(separator: ", "))
                    format = defaultEventFormat
                }
                if let event = dialogue(trimmed.dropFirst("dialogue:".count), format: format!, readOrder: events.count) {
                    events.append(event)
                }
            }
            // Comment lines and anything else in [Events] are dropped.
        }
        if !sawEvents {
            header.append("[Events]")
        }
        if format == nil {
            header.append("Format: " + defaultEventFormat.joined(separator: ", "))
        }
        return (Array((header.joined(separator: "\n") + "\n").utf8), events.sorted { $0.startTicks < $1.startTicks })
    }

    private static func dialogue(_ line: Substring, format: [String], readOrder: Int) -> ExternalASSEvent? {
        let names = format.map { $0.lowercased() }
        guard let startIndex = names.firstIndex(of: "start"), let endIndex = names.firstIndex(of: "end") else { return nil }
        // Text is last and may hold commas.
        let fields = line.split(separator: ",", maxSplits: max(0, format.count - 1), omittingEmptySubsequences: false)
            .enumerated().map { $0.offset == format.count - 1 ? String($0.element) : $0.element.trimmingCharacters(in: .whitespaces) }
        guard fields.count == format.count,
              let start = timestamp(Substring(fields[startIndex])),
              let end = timestamp(Substring(fields[endIndex])),
              end > start
        else { return nil }
        let rest = fields.enumerated().filter { $0.offset != startIndex && $0.offset != endIndex }.map(\.element)
        let data = ([String(readOrder)] + rest).joined(separator: ",")
        return ExternalASSEvent(startTicks: start, endTicks: end, data: Array(data.utf8))
    }

    // MARK: Timing

    /// `start --> end [settings]`, with SRT's comma or WebVTT's dot before the fraction and the hours optional.
    static func timing(_ line: String) -> (start: Int64, end: Int64, settings: String?)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let rightParts = right.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let endText = rightParts.first, let start = timestamp(Substring(left)), let end = timestamp(endText) else { return nil }
        let settings = rightParts.count > 1 ? rightParts[1].trimmingCharacters(in: .whitespaces) : nil
        return (start, end, settings?.isEmpty == false ? settings : nil)
    }

    /// `[h:]mm:ss[.,]fraction` in 100 ns ticks. ASS writes `h:mm:ss.cc`.
    static func timestamp(_ text: Substring) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsParts = parts[parts.count - 1].split(whereSeparator: { $0 == "." || $0 == "," })
        guard (1...2).contains(secondsParts.count),
              secondsParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let seconds = Int64(secondsParts[0]), seconds < 60,
              let minutes = Int64(parts[parts.count - 2]),
              let hours = parts.count == 3 ? Int64(parts[0]) : 0,
              hours >= 0, minutes >= 0
        else { return nil }
        var fraction: Int64 = 0
        if secondsParts.count == 2 {
            let digits = String(secondsParts[1].prefix(7))
            fraction = Int64(digits.padding(toLength: 7, withPad: "0", startingAt: 0)) ?? 0
        }
        return ((hours * 60 + minutes) * 60 + seconds) * 10_000_000 + fraction
    }
}
