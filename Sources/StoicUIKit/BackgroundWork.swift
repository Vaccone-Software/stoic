#if canImport(UIKit) && !os(watchOS)
internal import Stoic
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
/// - begins a background task and always ends it, on every exit path;
/// - runs `work` under a ``Deadline`` set from `backgroundTimeRemaining`, so
///   every retry, wait and timeout inside it already knows how long it has;
/// - cancels `work` with ``CancellationCause/systemExpiring`` when the
///   expiration handler fires, so cleanup can tell "the system took our time
///   away" from "the user cancelled".
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
        let task = Task { try await expiry.run(work) }
        let identifier = application.beginBackgroundTask(withName: name) {
            expiry.expire()
            task.cancel()
        }
        defer {
            if identifier != UIBackgroundTaskIdentifier.invalid { application.endBackgroundTask(identifier) }
        }
        let remaining = application.backgroundTimeRemaining
        if remaining.isFinite, remaining > 0 {
            return try await withTimeout(.milliseconds(Int64(remaining * 1000)), label: "background.\(name)") {
                try await task.value
            }
        }
        return try await task.value
    }
}
#endif
