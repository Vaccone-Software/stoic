internal import Synchronization

/// A counting semaphore for async code: at most `permits` bodies run at once.
///
/// Strictly first-in, first-out: a newcomer never overtakes a waiter, even
/// when a permit happens to be free at the moment it arrives behind one.
/// Waiting is bounded: a waiter leaves the queue when its task is cancelled
/// or ``Deadline/current`` passes, and a waiter that leaves never consumes a
/// permit — the classic leak in hand-written async semaphores, where a
/// permit is handed to a waiter whose cancellation is already under way.
///
/// The only way to hold a permit is ``withPermit(_:)``, which returns it on
/// success, failure and cancellation alike, so a permit cannot be leaked by
/// a missing release.
///
/// A task that already holds a permit and asks for another from the same
/// semaphore can deadlock itself once permits run out; Stoic reports that as
/// a `semaphore.reentrant` event at error level the moment it happens.
public final class AsyncSemaphore: Sendable, CustomStringConvertible {
    /// Names the semaphore in events and diagnostics.
    public let label: String

    /// The number of bodies that may run at once.
    public let capacity: Int

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Rejection?, Never>
    }

    private struct State {
        var available: Int
        var nextID: UInt64 = 0
        var queue: [Waiter] = []
        // Waiters that have an id but have not queued yet.
        var arriving: Set<UInt64> = []
        // Arriving waiters whose cancellation or deadline came first.
        var leftEarly: [UInt64: Rejection] = [:]
    }

    private let state: Mutex<State>

    public init(permits: Int, label: String) {
        precondition(permits >= 1, "a semaphore needs at least one permit")
        self.label = label
        self.capacity = permits
        self.state = Mutex(State(available: permits))
    }

    /// Permits free right now.
    public var availablePermits: Int {
        state.withLock { $0.available }
    }

    /// Tasks waiting right now.
    public var waiterCount: Int {
        state.withLock { $0.queue.count }
    }

    /// Runs `body` while holding a permit.
    ///
    /// - Throws: `.failed` with the body's error, or `.rejected` if the wait
    ///   ended before a permit was granted: `.cancelled` when the task was
    ///   cancelled, `.deadlineExceeded` when ``Deadline/current`` passed.
    public nonisolated(nonsending) func withPermit<R, Failure: Error>(
        _ body: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        try await withPermit(queueing: .unbounded, body)
    }

    /// How a caller that cannot have a permit at once is treated. A
    /// semaphore queues without limit (bounded by cancellation and
    /// deadlines); a bulkhead bounds the queue and says so in its own words.
    struct Queueing: Sendable {
        /// The most tasks allowed to wait; arrivals beyond it are refused.
        var limit: Int?
        /// The reason a refused arrival is given.
        var fullReason: Rejection.Reason
        /// The event reporting any refusal, whether full, cancelled or late.
        var rejectedEvent: EventName

        static let unbounded = Queueing(limit: nil, fullReason: .bulkheadFull, rejectedEvent: "semaphore.rejected")
    }

    /// `withPermit`, with the queue bounded as `queueing` says. The bound is
    /// checked in the same critical section that decides to queue, so it
    /// holds exactly however many tasks arrive at once.
    nonisolated(nonsending) func withPermit<R, Failure: Error>(
        queueing: Queueing,
        _ body: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        if HeldPermits.current.contains(ObjectIdentifier(self)) {
            Ambient.record(Event("semaphore.reentrant", level: .error, label: label, fields: [
                .init("capacity", .int(capacity)),
            ]))
        }
        if let rejection = await acquire(queueing) {
            throw .rejected(rejection)
        }
        defer { release() }
        let held = HeldPermits.current + [ObjectIdentifier(self)]
        let result: Result<R, Failure> = await HeldPermits.$current.withValue(held) {
            do throws(Failure) {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case .success(let value): return value
        case .failure(let failure): throw .failed(failure)
        }
    }

    /// Waits for a permit. Returns `nil` once granted, or why the wait ended.
    private nonisolated(nonsending) func acquire(_ queueing: Queueing) async -> Rejection? {
        if Task.isCancelled {
            return Rejection(.cancelled, label: label)
        }
        enum Admission { case granted, full(waiting: Int), wait(UInt64) }
        let admission = state.withLock { state -> Admission in
            if state.available > 0, state.queue.isEmpty {
                state.available -= 1
                return .granted
            }
            let waiting = state.queue.count + state.arriving.count
            if let limit = queueing.limit, waiting >= limit {
                return .full(waiting: waiting)
            }
            defer { state.nextID += 1 }
            state.arriving.insert(state.nextID)
            return .wait(state.nextID)
        }
        let id: UInt64
        switch admission {
        case .granted:
            return nil
        case .full(let waiting):
            Ambient.record(Event(queueing.rejectedEvent, level: .notice, label: label, fields: [
                .init("reason", .string(queueing.fullReason.rawValue), privacy: .public),
                .init("capacity", .int(capacity)),
                .init("waiting", .int(waiting)),
            ]))
            return Rejection(queueing.fullReason, label: label)
        case .wait(let ticket):
            id = ticket
        }
        defer {
            // Whatever ended the wait, this waiter is gone: forget it.
            state.withLock { state in
                state.arriving.remove(id)
                state.leftEarly.removeValue(forKey: id)
            }
        }

        let deadline = Deadline.current
        if let deadline, deadline.hasPassed {
            return Rejection(.deadlineExceeded, label: label)
        }
        return await withTaskGroup(of: Void.self) { group in
            if let deadline {
                group.addTask {
                    do {
                        try await deadline.clock.sleep(until: deadline.instant, tolerance: nil)
                        self.leave(id, because: Rejection(.deadlineExceeded, label: self.label))
                    } catch {}
                }
            }
            let waited = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Rejection?, Never>) in
                    enqueue(Waiter(id: id, continuation: continuation))
                }
            } onCancel: {
                leave(id, because: Rejection(.cancelled, label: label))
            }
            group.cancelAll()
            var outcome = waited
            if outcome?.reason == .cancelled, CancellationCause.current == .deadline {
                // Cancelled by an enclosing deadline: report it as one.
                outcome = Rejection(.deadlineExceeded, label: label)
            }
            if let outcome {
                Ambient.record(Event(queueing.rejectedEvent, level: .info, label: label, fields: [
                    .init("reason", .string(outcome.reason.rawValue), privacy: .public),
                    .init("capacity", .int(capacity)),
                ]))
            }
            return outcome
        }
    }

    private func enqueue(_ waiter: Waiter) {
        enum Next { case wait, grant, reject(Rejection) }
        let next = state.withLock { state -> Next in
            state.arriving.remove(waiter.id)
            if let rejection = state.leftEarly.removeValue(forKey: waiter.id) {
                return .reject(rejection)
            }
            if state.available > 0, state.queue.isEmpty {
                state.available -= 1
                return .grant
            }
            state.queue.append(waiter)
            return .wait
        }
        switch next {
        case .wait: break
        case .grant: waiter.continuation.resume(returning: nil)
        case .reject(let rejection): waiter.continuation.resume(returning: rejection)
        }
    }

    /// Takes waiter `id` out of the queue, if it is still waiting.
    private func leave(_ id: UInt64, because rejection: Rejection) {
        let waiter = state.withLock { state -> Waiter? in
            if let index = state.queue.firstIndex(where: { $0.id == id }) {
                return state.queue.remove(at: index)
            }
            if state.arriving.contains(id), state.leftEarly[id] == nil {
                // Not queued yet: it will find this on arrival and leave.
                state.leftEarly[id] = rejection
            }
            // Otherwise it was already granted a permit — the body will run
            // and see the cancellation itself — or it has already gone.
            return nil
        }
        waiter?.continuation.resume(returning: rejection)
    }

    private func release() {
        let next = state.withLock { state -> Waiter? in
            if state.queue.isEmpty {
                state.available += 1
                precondition(state.available <= capacity, "AsyncSemaphore \(label): released more permits than it has")
                return nil
            }
            return state.queue.removeFirst()
        }
        // The permit passes directly to the next waiter.
        next?.continuation.resume(returning: nil)
    }

    public var description: String {
        let (available, waiting) = state.withLock { ($0.available, $0.queue.count) }
        return "AsyncSemaphore(\(label): \(available)/\(capacity) free, \(waiting) waiting)"
    }
}

/// A mutual-exclusion lock for async code: one body at a time, first come,
/// first served.
///
/// The cure for actor reentrancy's check–await–act race: state an actor
/// checks before an `await` may have changed by the time the `await` returns,
/// unless the whole sequence holds a lock that spans it. Unlike `Mutex`, an
/// `AsyncMutex` may be held across `await`.
public final class AsyncMutex: Sendable, CustomStringConvertible {
    private let semaphore: AsyncSemaphore

    public init(label: String) {
        semaphore = AsyncSemaphore(permits: 1, label: label)
    }

    public var label: String { semaphore.label }

    /// Runs `body` holding the lock.
    ///
    /// - Throws: `.failed` with the body's error, or `.rejected` when the
    ///   wait was cancelled or outlived ``Deadline/current``.
    public nonisolated(nonsending) func withLock<R, Failure: Error>(
        _ body: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        try await semaphore.withPermit(body)
    }

    public var description: String {
        "AsyncMutex(\(label))"
    }
}

/// The semaphores whose permits the current task (or an ancestor) holds.
enum HeldPermits {
    @TaskLocal static var current: [ObjectIdentifier] = []
}
