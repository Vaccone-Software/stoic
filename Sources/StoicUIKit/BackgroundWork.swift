#if canImport(UIKit) && !os(watchOS)
internal import Stoic
internal import Synchronization
internal import UIKit

/// Runs work that should finish even if the user leaves the app — saving a
/// draft, flushing an outbox — within the time the system grants.
///
/// iOS gives a backgrounded app a short, variable amount of time, and calls
/// an expiration handler when it is up; work still running then must stop at
/// once or the app is killed. Hand-written versions forget to end the
/// background task on one of their exit paths, or ignore the expiration
/// handler. This one:
///
/// - begins a background task and always ends it, on every exit path — and
///   in the expiration handler itself, as the system requires, without
///   waiting for the work to unwind;
/// - does not run `work` when the system refuses the assertion
///   (`beginBackgroundTask` returns `.invalid`): there is nothing to keep
///   the process awake, and no deadline when `backgroundTimeRemaining` is
///   0. The call throws `CancellationError` with cause
///   `CancellationCause.systemExpiring`, so the caller can tell a refusal
///   from a flush that finished;
/// - runs `work` under a `Deadline` set from `backgroundTimeRemaining`, so
///   every retry, wait and timeout inside it already knows how long it has;
/// - cancels `work` with `CancellationCause.systemExpiring` when the
///   expiration handler fires, so cleanup can tell "the system took our time
///   away" from "the user cancelled";
/// - cancels `work` when the calling task is cancelled.
///
///     func sceneDidEnterBackground(_ scene: UIScene) {
///         Task { try await BackgroundWork.run(named: "flush-outbox") { try await outbox.deliverPending() } }
///     }
@MainActor
public enum BackgroundWork {
    /// Runs `work` as background work. Throws `CancellationError` (cause
    /// `systemExpiring`) if the system's time ran out, or if it refused to
    /// grant any — in which case `work` does not run.
    public static func run<R: Sendable>(
        named name: String,
        _ work: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        let application = UIApplication.shared
        let expiry = ExpiringWork()
        let token = BackgroundTaskToken()
        let identifier = application.beginBackgroundTask(withName: name) {
            // The system requires the task ended before this handler
            // returns; the work is told to stop, not waited for.
            expiry.expire()
            MainActor.assumeIsolated { token.end(in: application) }
        }
        token.begin(identifier)
        defer { token.end(in: application) }
        // `.invalid` means the system will not grant time. `end` is a no-op
        // for it, and a remaining time of 0 becomes no deadline, so the work
        // would run with nothing keeping the process awake.
        let granted = identifier != .invalid
        let limit = granted ? ExpiringWork.limit(fromSecondsRemaining: application.backgroundTimeRemaining) : nil
        return try await expiry.runIfGranted(granted, within: limit, label: "background.\(name)", work)
    }
}

/// A background task identifier that is ended exactly once, by whichever of
/// the expiration handler and the normal exit gets there first.
private final class BackgroundTaskToken: Sendable {
    private let identifier = Mutex(UIBackgroundTaskIdentifier.invalid)

    func begin(_ identifier: UIBackgroundTaskIdentifier) {
        self.identifier.withLock { $0 = identifier }
    }

    @MainActor
    func end(in application: UIApplication) {
        let identifier = identifier.withLock { identifier in
            defer { identifier = .invalid }
            return identifier
        }
        if identifier != .invalid { application.endBackgroundTask(identifier) }
    }
}
#endif
