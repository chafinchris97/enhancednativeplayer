import Foundation

public enum EnhancedPlayerError: Error, LocalizedError, Sendable {
    case http(status: Int, url: URL)
    case rangeRequestsUnsupported(URL)
    case network(String)
    case ffmpeg(operation: String, code: Int32, message: String)
    case noVideoStream
    case unsupportedVideoCodec(String)
    case noKeyframeIndex
    case segmentOutOfRange(Int)
    case unknownAudioTrack(Int)
    case cancelled
    case serverFailedToStart

    public var errorDescription: String? {
        switch self {
        case .http(let status, let url): "HTTP \(status) from \(url.absoluteString)"
        case .rangeRequestsUnsupported(let url): "\(url.absoluteString) did not answer a range request with 206 Partial Content"
        case .network(let message): "Network error: \(message)"
        case .ffmpeg(let operation, let code, let message): "\(operation) failed (\(code)): \(message)"
        case .noVideoStream: "The file has no video stream"
        case .unsupportedVideoCodec(let name): "Video codec \(name) cannot be remuxed for AVPlayer (H.264 and HEVC only)"
        case .noKeyframeIndex: "The file carries no keyframe index (Matroska Cues / MP4 stss), so segments cannot be planned without reading the whole file"
        case .segmentOutOfRange(let index): "Segment \(index) is outside the playlist"
        case .unknownAudioTrack(let index): "Audio track \(index) does not exist"
        case .cancelled: "Cancelled"
        case .serverFailedToStart: "The local HLS server did not start"
        }
    }
}
