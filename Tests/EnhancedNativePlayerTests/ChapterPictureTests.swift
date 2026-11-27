import Foundation
import ImageIO
import Logging
import Testing
@testable import EnhancedNativePlayer

/// Pictures made from the video for chapters without one. Opt-in: set `ENP_CHAPTER_PICTURES_FILE`
/// to a local video file, which is served over HTTP for the test. Pictures are made for chapters
/// every 10 s and, with `ENP_CHAPTER_PICTURES_OUT` set, written there as JPEGs.
struct ChapterPictureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENP_CHAPTER_PICTURES_FILE"] != nil))
    func picturesTheVideoAtEachChapter() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["ENP_CHAPTER_PICTURES_FILE"]!
        let server = try await KeepAliveServer(file: Data(contentsOf: URL(fileURLWithPath: path)))
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("enp-chapters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await RemoteFile.open(url: server.url, headers: [:], directory: directory, diskBudget: 0, logger: Logger(label: "test"))
        let token = CancellationToken()
        let media = try MediaProbe.probe(file: file, token: token)
        let thumbnailer = try #require(ChapterThumbnailer(file: file, media: media, token: token, logger: Logger(label: "test")))

        var starts: [Double] = []
        var start = 0.0
        while start < media.durationSeconds { starts.append(start); start += 10 }
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : media.durationSeconds
            let began = ContinuousClock.now
            let picture = try #require(thumbnailer.picture(for: Duration.seconds(start) ..< Duration.seconds(end)), "no picture at \(start) s")
            let elapsed = ContinuousClock.now - began
            let source = try #require(CGImageSourceCreateWithData(picture as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
            #expect(height <= ChapterThumbnailer.height)
            print("Chapter at \(start) s: \(picture.count) bytes, height \(height), \(elapsed)")
            if let out = environment["ENP_CHAPTER_PICTURES_OUT"] {
                let folder = URL(fileURLWithPath: out, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try picture.write(to: folder.appendingPathComponent("\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)_\(Int(start)).jpg"))
            }
        }
    }
}
