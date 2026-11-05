import AVFoundation
import Foundation

/// Waits out a display mode switch by its start and end notifications.
///
/// `AVDisplayManager.isDisplayModeSwitchInProgress` cannot be trusted for this. AVKit
/// derives it from a count shared by the whole process: each delivery of PineBoard's
/// `com.apple.pineboard.display_mode_switch_active` Darwin notification reads the
/// current state and counts one up when it is set, one down when it is clear. Darwin
/// notifications posted while an app is suspended are delivered together on resume, and
/// every one of them reads the state as it is by then, so the count ends up off by however
/// many switches PineBoard made in the meantime. Once it is above zero the property stays
/// true until the process exits. The start and end notifications AVKit posts are sent
/// on every delivery, whatever the count, so they still describe the switch the app asked for.
enum DisplayModeSwitch {
    enum Event: Equatable {
        case started
        case ended
    }

    enum Outcome: Equatable {
        case switched
        case neverStarted
        /// The switch had started but not ended by `switchTimeout`.
        case neverEnded
    }

    /// Waits for a display mode switch requested just before the call. `events` returns
    /// the start and end notifications seen since the request, in order. Returns once a
    /// switch has ended and `settle` has passed without another starting, after
    /// `startTimeout` if nothing happens, or after `switchTimeout` if a switch never ends.
    /// Throws when cancelled.
    @MainActor
    @discardableResult
    static func wait(
        events: () -> [Event],
        startTimeout: Duration = .seconds(10),
        switchTimeout: Duration = .seconds(15),
        settle: Duration = .milliseconds(500),
        poll: Duration = .milliseconds(50)
    ) async throws -> Outcome {
        let clock = ContinuousClock()
        let startDeadline = clock.now + startTimeout
        while events().isEmpty {
            if clock.now >= startDeadline { return .neverStarted }
            try await clock.sleep(for: poll)
        }
        let switchDeadline = clock.now + switchTimeout
        while true {
            while events().last == .started {
                if clock.now >= switchDeadline { return .neverEnded }
                try await clock.sleep(for: poll)
            }
            // A frame rate change and a dynamic range change can come as two switches.
            let seen = events().count
            try await clock.sleep(for: settle)
            if events().count == seen { return .switched }
        }
    }
}

#if os(tvOS)
import AVKit

/// Records the display mode switch notifications from the moment it is created.
@MainActor
final class DisplayModeSwitchRecorder {
    private(set) var events: [DisplayModeSwitch.Event] = []
    private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for (name, event) in [(Notification.Name.AVDisplayManagerModeSwitchStart, DisplayModeSwitch.Event.started), (.AVDisplayManagerModeSwitchEnd, .ended)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.events.append(event) }
            })
        }
    }

    func invalidate() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
#endif

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
