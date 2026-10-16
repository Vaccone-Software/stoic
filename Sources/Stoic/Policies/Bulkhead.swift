/// Limits how many operations run at once, and how many may wait, so that one
/// slow dependency cannot take every task the app has.
///
/// Named for the watertight compartments of a ship: when a dependency hangs,
/// the operations stuck on it fill their compartment and no further. At most
/// `maxConcurrent` operations run; up to `queueLimit` more wait their turn,
/// first in, first out; the next arrival is rejected at once with
/// ``Rejection/Reason/bulkheadFull``. Refusing early is the point: a queue
/// that grows without bound turns a slow dependency into a slow app.
///
/// The default `queueLimit` of 0 sheds load the moment the compartment is
/// full (Envoy's and tower's behaviour). Give it room when short bursts are
/// expected and waiting a moment is better than failing.
///
/// A bulkhead is a ``AsyncSemaphore`` whose queue is bounded in the same
/// critical section that decides to queue, so the limit holds exactly however
/// many tasks arrive together. A waiter that is cancelled, or whose
/// ``Deadline/current`` passes, leaves the queue without taking a slot.
///
///     let bulkhead = Bulkhead(maxConcurrent: 8, queueLimit: 16, label: "uploads")
///     let reply = try await bulkhead.execute { try await upload(file) }
public final class Bulkhead: Policy, CustomStringConvertible {
    /// Names the bulkhead in rejections and events.
    public let label: String

    /// The number of operations that may run at once.
    public let maxConcurrent: Int

    /// The number of operations that may wait for a slot.
    public let queueLimit: Int

    private let semaphore: AsyncSemaphore

    public init(maxConcurrent: Int, queueLimit: Int = 0, label: String) {
        precondition(maxConcurrent >= 1, "a bulkhead needs room for at least one operation")
        precondition(queueLimit >= 0, "a bulkhead's queue cannot have a negative size")
        self.label = label
        self.maxConcurrent = maxConcurrent
        self.queueLimit = queueLimit
        self.semaphore = AsyncSemaphore(permits: maxConcurrent, label: label)
    }

    /// Operations running right now.
    public var activeCount: Int {
        maxConcurrent - semaphore.availablePermits
    }

    /// Operations waiting for a slot right now.
    public var queuedCount: Int {
        semaphore.waiterCount
    }

    /// Runs `operation` when a slot is free.
    ///
    /// - Throws: `.failed` with the operation's error, or `.rejected`:
    ///   `.bulkheadFull` when the slots and the queue are both full,
    ///   `.cancelled` when the task was cancelled, `.deadlineExceeded` when
    ///   ``Deadline/current`` has passed or passes while waiting.
    public nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        if let refusal = Rejection.refusedBeforeStart(label: label) {
            Ambient.record(Event("bulkhead.rejected", level: .info, label: label, fields: [
                .init("reason", .string(refusal.reason.rawValue), privacy: .public),
                .init("capacity", .int(maxConcurrent)),
            ]))
            throw .rejected(refusal)
        }
        let queueing = AsyncSemaphore.Queueing(limit: queueLimit, fullReason: .bulkheadFull, rejectedEvent: "bulkhead.rejected")
        return try await semaphore.withPermit(queueing: queueing) { () async throws(Failure) -> R in
            // Time queued here is not the dependency's: a breaker outside
            // measures from now.
            DispatchMark.dispatched()
            return try await operation()
        }
    }

    public var description: String {
        "Bulkhead(\(label): \(activeCount)/\(maxConcurrent) running, \(queuedCount)/\(queueLimit) waiting)"
    }
}
