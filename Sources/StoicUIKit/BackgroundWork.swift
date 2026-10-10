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
/// - runs `work` under a ``Deadline`` set from `backgroundTimeRemaining`, so
///   every retry, wait and timeout inside it already knows how long it has;
/// - cancels `work` with ``CancellationCause/systemExpiring`` when the
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
    /// `systemExpiring`) if the system's time ran out first.
    public static func run<R: Sendable>(
        named name: String,
        _ work: @escaping @Sendable () async throws -> R
    ) async throws -> R {
        let application = UIApplication.shared
        let expiry = ExpiringWork()
        let token = BackgroundTaskToken()
        token.begin(application.beginBackgroundTask(withName: name) {
            // The system requires the task ended before this handler
            // returns; the work is told to stop, not waited for.
            expiry.expire()
            MainActor.assumeIsolated { token.end(in: application) }
        })
        defer { token.end(in: application) }
        let limit = ExpiringWork.limit(fromSecondsRemaining: application.backgroundTimeRemaining)
        return try await expiry.run(within: limit, label: "background.\(name)", work)
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
