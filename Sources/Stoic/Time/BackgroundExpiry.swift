/// A cancellation cause cell for work whose time a host system can take
/// away. Used by the UIKit background-work bridge; public so other hosts
/// (a BGTask handler, an app extension) can do the same.
public final class ExpiringWork: Sendable {
    private let cause = CancellationCauseBox(parent: nil)

    public init() {}

    /// Runs `work` so that ``expire()`` is reported to it as
    /// ``CancellationCause/systemExpiring``.
    public func run<R: Sendable>(_ work: @Sendable () async throws -> R) async throws -> R {
        try await CancellationCauseBox.$current.withValue(cause) {
            try await work()
        }
    }

    /// Records that the system is taking the time back. Call before
    /// cancelling the task running the work.
    public func expire() {
        cause.record(.systemExpiring)
    }
}
