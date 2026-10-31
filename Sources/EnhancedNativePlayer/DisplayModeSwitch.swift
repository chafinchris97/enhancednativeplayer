import AVFoundation
import Foundation

enum DisplayModeSwitch {
    /// Waits for a display mode switch requested just before the call: until it ends plus
    /// `settle`, or for `startTimeout` if it never starts. Throws when cancelled.
    @MainActor
    static func wait(
        isSwitching: () -> Bool,
        startTimeout: Duration = .seconds(10),
        settle: Duration = .milliseconds(500),
        poll: Duration = .milliseconds(50)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + startTimeout
        while !isSwitching() {
            if clock.now >= deadline { return }
            try await clock.sleep(for: poll)
        }
        while isSwitching() {
            try await clock.sleep(for: poll)
        }
        try await clock.sleep(for: settle)
    }
}

enum DisplayRefusal {
    /// Whether an item failed because AVPlayer will not present this master on the current
    /// display: no compatible alternates (-11868), the same for an HDR master on an SDR
    /// display (-11848), or every variant filtered out when the master was parsed (-1002).
    static func matches(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case AVFoundationErrorDomain: return error.code == -11868 || error.code == -11848
        case NSURLErrorDomain: return error.code == NSURLErrorUnsupportedURL
        default: return false
        }
    }
}
