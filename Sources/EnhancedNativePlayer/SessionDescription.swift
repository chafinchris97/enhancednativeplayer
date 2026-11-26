import EPLibavutil
import Foundation

/// The lines that open a session's log: what it runs on, how the engine is tuned, and what is in
/// the file with what the engine does with each stream. Logged at notice, so the unified log keeps
/// them on disk with the warnings that follow.
enum SessionDescription {
    static func environment(configuration: EnhancedPlayerConfiguration) -> String {
        let process = ProcessInfo.processInfo
        let memory = process.physicalMemory >> 20
        let headers = configuration.httpHeaders.keys.sorted().joined(separator: ",")
        return "Device \(deviceModel), \(process.operatingSystemVersionString), \(process.activeProcessorCount) cores, \(memory) MB, thermal \(process.thermalState.logName); FFmpeg \(String(cString: av_version_info())); segments \(String(format: "%g", configuration.segmentDuration)) s, \(configuration.segmentsAhead) ahead, source cache \(configuration.sourceCacheBytes >> 20) MB, header names [\(headers)]"
    }

    static func media(_ media: MediaInfo, file: URL) -> [String] {
        var lines = ["File \(file.host ?? "?")/…/\(file.lastPathComponent): \(media.formatName), \(media.fileSize >> 20) MB, \(String(format: "%.0f", media.durationSeconds)) s\(media.bitRate.map { ", \($0 / 1000) kb/s" } ?? ""), \(media.chapters.count) chapters"]
        lines.append(video(media.video))
        lines += media.audio.map(audio)
        lines += media.subtitles.map(subtitle)
        return lines
    }

    private static func video(_ video: VideoTrack) -> String {
        var parts: [String] = []
        if let rendered = video.rendered {
            parts.append("\(rendered.codecName) \(video.width)×\(video.height)")
        } else {
            parts.append("\(video.codec == .hevc ? "hevc" : "h264") \(video.width)×\(video.height) profile \(video.profile) level \(video.level)")
        }
        parts.append(video.frameRate.map { String(format: "%.3f fps", $0) } ?? "variable fps")
        parts.append(video.range.rawValue)
        if let dv = video.dolbyVision { parts.append("Dolby Vision profile \(dv.profile)") }
        if video.hdr10Plus { parts.append("HDR10+") }
        if let bitRate = video.bitRate { parts.append("\(bitRate / 1000) kb/s") }
        parts.append("reorder depth \(video.reorderDepth)")
        let route: String
        if let rendered = video.rendered {
            let pixelFormat = rendered.pixelFormat < 0 ? "pixel format unknown" : av_get_pix_fmt_name(AVPixelFormat(rawValue: rendered.pixelFormat)).map { String(cString: $0) } ?? "pixel format \(rendered.pixelFormat)"
            route = "decoded and drawn by the engine (\(pixelFormat)) over the \(video.codec == .hevc ? "HEVC" : "H.264") placeholder"
        } else {
            route = "copied as \(video.sampleEntry)"
        }
        return "Video: \(parts.joined(separator: ", ")) → \(route)"
    }

    private static func audio(_ track: AudioTrack) -> String {
        let name = track.profileName.map { "\(track.codecName) (\($0))" } ?? track.codecName
        let route = track.delivery == .copy ? "copied" : "transcoded to FLAC, \(track.deliveredChannels) channels"
        let flags = [track.isDefault ? "default" : nil, track.isAtmos ? "Atmos" : nil].compactMap { $0 }
        return "Audio \(track.index): \(name), \(track.channels) ch, \(track.sampleRate) Hz\(track.bitRate.map { ", \($0 / 1000) kb/s" } ?? ""), \(track.language ?? "und")\(flags.isEmpty ? "" : ", " + flags.joined(separator: ", ")) → \(route)"
    }

    private static func subtitle(_ track: SubtitleTrack) -> String {
        let route: String
        if track.isPGS { route = "drawn by the engine (PGS)" }
        else if track.isASS { route = "drawn by libass" }
        else if track.isExternal || track.textFormat != nil { route = "WebVTT" }
        else { route = "listed, not shown" }
        let flags = [track.isExternal ? "external" : nil, track.isDefault ? "default" : nil, track.isForced ? "forced" : nil].compactMap { $0 }
        return "Subtitle \(track.index): \(track.codecName), \(track.language ?? "und")\(flags.isEmpty ? "" : ", " + flags.joined(separator: ", ")) → \(route)"
    }

    /// `AppleTV14,1`, or the simulated model's identifier in the simulator.
    static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return "\(simulated) (simulator)" }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension ProcessInfo.ThermalState {
    var logName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
