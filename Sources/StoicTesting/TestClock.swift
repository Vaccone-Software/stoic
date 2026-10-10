public import Stoic
internal import Synchronization

/// A clock that moves only when a test moves it.
///
/// Sleepers on a `TestClock` suspend until the test advances time past their
/// deadline. Advancing wakes them in deadline order (ties in the order they
/// went to sleep), so a thirty-second backoff takes no real time and happens
/// the same way on every run.
///
/// Waking a sleeper schedules its task; it does not run it to its next
/// suspension. When a test needs to know that woken work has gone back to
/// sleep, it waits for that explicitly with ``waitForSleepers(count:)``,
/// which is exact, rather than relying on yields, which are not.
public final class TestClock: Clock, Sendable {
    public typealias Duration = Swift.Duration

    /// A point in virtual time: the duration since the clock was created.
    public struct Instant: InstantProtocol, CustomStringConvertible {
        public typealias Duration = Swift.Duration
        public var offset: Swift.Duration

        public init(offset: Swift.Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Swift.Duration) -> Instant {
            let (sum, overflow) = offset.attoseconds.addingReportingOverflow(duration.attoseconds)
            guard overflow else { return Instant(offset: Swift.Duration(attoseconds: sum)) }
            return Instant(offset: Swift.Duration(attoseconds: duration > .zero ? .max : .min))
        }

        public func duration(to other: Instant) -> Swift.Duration {
            let (difference, overflow) = other.offset.attoseconds.subtractingReportingOverflow(offset.attoseconds)
            guard overflow else { return Swift.Duration(attoseconds: difference) }
            return Swift.Duration(attoseconds: other.offset > offset ? .max : .min)
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        public var description: String { "+\(offset)" }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Swift.Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct CountWaiter {
        let id: UInt64
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Swift.Duration = .zero
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
        // Sleepers with an id that have not registered yet, and those of
        // them whose cancellation arrived first.
        var arriving: Set<UInt64> = []
        var cancelledBeforeSleeping: Set<UInt64> = []
        var countWaiters: [CountWaiter] = []
        var totalSleeps = 0

        // Waiters whose count is now met, removed from the list.
        mutating func takeSatisfiedCountWaiters() -> [CheckedContinuation<Void, Never>] {
            let ready = countWaiters.filter { $0.count <= sleepers.count }
            countWaiters.removeAll { $0.count <= sleepers.count }
            return ready.map(\.continuation)
        }
    }

    private let state = Mutex(State())
    private let erasure = Mutex<AnyClock?>(nil)

    public init() {}

    /// This clock, erased, for ``Ambient`` or any `clock:` parameter.
    ///
    /// Always the same erasure, so instants and deadlines taken through it
    /// anywhere in a test compare exactly.
    public var erased: AnyClock {
        erasure.withLock { erasure in
            if let erasure { return erasure }
            let created = AnyClock(self, name: "test")
            erasure = created
            return created
        }
    }

    public var now: Instant {
        state.withLock { Instant(offset: $0.now) }
    }

    public var minimumResolution: Swift.Duration { .zero }

    /// How many tasks are asleep on this clock right now.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// How many times anything has gone to sleep on this clock.
    public var totalSleeps: Int {
        state.withLock { $0.totalSleeps }
    }

    /// The deadlines of every current sleeper, earliest first.
    public var pendingDeadlines: [Instant] {
        state.withLock { $0.sleepers.map { Instant(offset: $0.deadline) }.sorted() }
    }

    public func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            state.arriving.insert(state.nextID)
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wake, cancel, sleep([CheckedContinuation<Void, Never>]) }
                let outcome = state.withLock { state -> Outcome in
                    state.totalSleeps += 1
                    state.arriving.remove(id)
                    if state.cancelledBeforeSleeping.remove(id) != nil { return .cancel }
                    if deadline.offset <= state.now { return .wake }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline.offset, continuation: continuation))
                    return .sleep(state.takeSatisfiedCountWaiters())
                }
                switch outcome {
                case .wake: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .sleep(let waiters): waiters.forEach { $0.resume() }
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index)
                }
                if state.arriving.contains(id) {
                    state.cancelledBeforeSleeping.insert(id)
                }
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward by `duration`, waking every sleeper whose deadline
    /// falls within it, in deadline order.
    ///
    /// Between distinct deadlines, `advance` yields so that work woken at an
    /// earlier deadline gets a chance to run, and may go back to sleep at a
    /// deadline that also falls within the advance. Yielding is best effort;
    /// tests that depend on woken work having settled should follow up with
    /// ``waitForSleepers(count:)``.
    public func advance(by duration: Swift.Duration) async {
        await advance(to: now.advanced(by: duration))
    }

    /// Moves time forward to `instant`. Moving backwards is a no-op.
    public func advance(to instant: Instant) async {
        while true {
            let due = state.withLock { state -> [Sleeper] in
                guard let earliest = state.sleepers.map(\.deadline).min(), earliest <= instant.offset else {
                    state.now = max(state.now, instant.offset)
                    return []
                }
                state.now = max(state.now, earliest)
                let due = state.sleepers.filter { $0.deadline <= earliest }
                state.sleepers.removeAll { $0.deadline <= earliest }
                return due.sorted { $0.id < $1.id }
            }
            if due.isEmpty { break }
            for sleeper in due { sleeper.continuation.resume() }
            await yieldRepeatedly()
        }
    }

    /// Advances to the earliest pending deadline, if there is one.
    ///
    /// - Returns: Whether any sleeper was woken.
    @discardableResult
    public func advanceToNextDeadline() async -> Bool {
        guard let next = pendingDeadlines.first else { return false }
        await advance(to: next)
        return true
    }

    /// Suspends until at least `count` tasks are asleep on this clock, or
    /// until the waiting task is cancelled — so a test that waits for a
    /// sleeper that never comes ends with its time limit instead of hanging.
    public func waitForSleepers(count: Int = 1) async {
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let satisfied = state.withLock { state -> Bool in
                    if state.sleepers.count >= count || Task.isCancelled { return true }
                    state.countWaiters.append(CountWaiter(id: id, count: count, continuation: continuation))
                    return false
                }
                if satisfied { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CountWaiter? in
                guard let index = state.countWaiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.countWaiters.remove(at: index)
            }
            waiter?.continuation.resume()
        }
    }

    private func yieldRepeatedly() async {
        for _ in 0..<64 { await Task.yield() }
    }
}
