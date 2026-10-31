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
