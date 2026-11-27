import Foundation
import Testing
@testable import EnhancedNativePlayer

struct SubtitleSegmentCacheTests {
    /// After a seek, reads for segments away from the new position stop; the others finish.
    @Test func aSeekStopsTheReadsItLeftBehind() async throws {
        let cache = SubtitleSegmentCache<Int>()
        let parent = CancellationToken()

        func load(_ segment: Int) -> Task<Int, Error> {
            let token = CancellationToken(parent: parent)
            return Task {
                try await cache.value(track: 0, segment: segment, token: token) {
                    // Stands in for a read that walks the file until it is done or stopped.
                    let deadline = Date().addingTimeInterval(2)
                    while Date() < deadline {
                        try token.throwIfCancelled()
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    return segment
                }
            }
        }

        let old = load(150)
        let near = load(200)
        try await Task.sleep(for: .milliseconds(100))
        await cache.cancelLoads(outside: 199...206)

        await #expect(throws: EnhancedPlayerError.self) { try await old.value }
        #expect(try await near.value == 200)
    }
}
