internal import Dispatch
public import Stoic
internal import Synchronization
public import Testing

/// A clock that moves only when a test moves it.
///
/// Sleepers on a `TestClock` suspend until the test advances time past their
/// deadline. Advancing wakes them in deadline order (ties in the order they
/// went to sleep), so a thirty-second backoff takes no real time and happens
/// the same way on every run.
///
/// Waking a sleeper schedules its task; it does not run it to its next
/// suspension. When a test needs to know that woken work has gone back to
/// sleep, it waits for that explicitly with ``waitForSleepers(count:timeout:sourceLocation:)``,
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

    private enum SleepOutcome { case wake, cancel, sleep }

    private struct Sleeper {
        let id: UInt64
        let deadline: Swift.Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// What a `waitForSleepers` call is waiting for.
    private enum Target {
        /// At least this many asleep right now.
        case asleep(Int)
        /// `totalSleeps` has reached this.
        case totalSleeps(Int)
    }

    private enum WaitResult {
        case satisfied, timedOut, cancelled
    }

    private struct CountWaiter {
        let id: UInt64
        let target: Target
        let continuation: CheckedContinuation<WaitResult, Never>
    }

    private struct State {
        var now: Swift.Duration = .zero
        var nextID: UInt64 = 0
        // By id, with a heap of (deadline, id) beside it: the earliest is
        // found in O(log n), not by scanning every sleeper. A cancelled
        // sleeper leaves its heap entry behind until it surfaces (or the
        // heap is rebuilt); the dictionary is the truth.
        var sleepers: [UInt64: Sleeper] = [:]
        var deadlines = DeadlineHeap()
        // Sleepers with an id that have not registered yet, and those of
        // them whose cancellation arrived first.
        var arriving: Set<UInt64> = []
        var cancelledBeforeSleeping: Set<UInt64> = []
        var countWaiters: [CountWaiter] = []
        var totalSleeps = 0
        // A wait for sleepers timed out: the test has already failed, and
        // nothing will move this clock the way it meant to. Every sleep now
        // ends at once, with `CancellationError`, so that whatever the test
        // awaits can finish and the failure is one test's, not the run's.
        var aborted = false

        mutating func add(_ sleeper: Sleeper) {
            sleepers[sleeper.id] = sleeper
            deadlines.push(deadline: sleeper.deadline, id: sleeper.id)
        }

        mutating func remove(id: UInt64) -> Sleeper? {
            let removed = sleepers.removeValue(forKey: id)
            // Cancelled sleepers leave heap entries; rebuild before they
            // outnumber the live ones.
            if removed != nil, deadlines.count > 2 * sleepers.count + 64 {
                deadlines = DeadlineHeap(sleepers.values.map { ($0.deadline, $0.id) })
            }
            return removed
        }

        /// The earliest deadline of a live sleeper.
        mutating func earliestDeadline() -> Swift.Duration? {
            while let top = deadlines.top {
                if sleepers[top.id] != nil { return top.deadline }
                deadlines.pop()
            }
            return nil
        }

        /// Removes the sleepers whose deadline is the earliest, if it is not
        /// after `limit`, in the order they went to sleep, and moves `now` to
        /// it. Empty when nothing is due.
        mutating func takeEarliest(upTo limit: Swift.Duration) -> [Sleeper] {
            guard let earliest = earliestDeadline(), earliest <= limit else { return [] }
            now = max(now, earliest)
            var due: [Sleeper] = []
            while let top = deadlines.top, top.deadline == earliest {
                deadlines.pop()
                if let sleeper = sleepers.removeValue(forKey: top.id) { due.append(sleeper) }
            }
            return due.sorted { $0.id < $1.id }
        }

        func isMet(_ target: Target) -> Bool {
            switch target {
            case .asleep(let count): sleepers.count >= count
            case .totalSleeps(let total): totalSleeps >= total
            }
        }

        // Waiters whose target is now met, removed from the list.
        mutating func takeSatisfiedCountWaiters() -> [CheckedContinuation<WaitResult, Never>] {
            var ready: [CheckedContinuation<WaitResult, Never>] = []
            var waiting: [CountWaiter] = []
            for waiter in countWaiters {
                if isMet(waiter.target) { ready.append(waiter.continuation) } else { waiting.append(waiter) }
            }
            if !ready.isEmpty { countWaiters = waiting }
            return ready
        }
    }

    private let state = Mutex(State())
    private let erasure = Mutex<AnyClock?>(nil)
    // Told, after the fact, of every call to `sleep`: how a simulation learns
    // that something outside it has gone to sleep on its clock.
    private let observer = Mutex<(@Sendable () -> Void)?>(nil)

    /// Calls `handler` after every call to `sleep(until:)`, once it has
    /// registered (or returned at once, or been cancelled), on the calling
    /// thread. A simulation's driver uses it to learn that a task it does
    /// not drive has gone to sleep on its clock, instead of timing out.
    func observeSleeps(_ handler: (@Sendable () -> Void)?) {
        observer.withLock { $0 = handler }
    }

    public init() {}

    /// This clock, erased, for `Ambient` or any `clock:` parameter.
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
        state.withLock { $0.sleepers.values.map { Instant(offset: $0.deadline) }.sorted() }
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
                let (outcome, waiters) = state.withLock { state -> (SleepOutcome, [CheckedContinuation<WaitResult, Never>]) in
                    state.totalSleeps += 1
                    state.arriving.remove(id)
                    if state.cancelledBeforeSleeping.remove(id) != nil || state.aborted { return (.cancel, state.takeSatisfiedCountWaiters()) }
                    if deadline.offset <= state.now { return (.wake, state.takeSatisfiedCountWaiters()) }
                    state.add(Sleeper(id: id, deadline: deadline.offset, continuation: continuation))
                    return (.sleep, state.takeSatisfiedCountWaiters())
                }
                switch outcome {
                case .wake: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .sleep: break
                }
                waiters.forEach { $0.resume(returning: .satisfied) }
                // Last, so a driver woken by it finds the sleeper registered.
                observer.withLock { $0 }?()
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let sleeper = state.remove(id: id) {
                    return sleeper
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
    /// ``waitForSleepers(count:timeout:sourceLocation:)``.
    public func advance(by duration: Swift.Duration) async {
        await advance(to: now.advanced(by: duration))
    }

    /// Moves time forward to `instant`. Moving backwards is a no-op.
    public func advance(to instant: Instant) async {
        while true {
            let due = state.withLock { state -> [Sleeper] in
                let due = state.takeEarliest(upTo: instant.offset)
                if due.isEmpty { state.now = max(state.now, instant.offset) }
                return due
            }
            if due.isEmpty { break }
            for sleeper in due { sleeper.continuation.resume() }
            await yieldRepeatedly()
        }
    }

    /// Moves to the earliest pending deadline and wakes every sleeper due
    /// then, in the order they went to sleep, without suspending: for a
    /// driver that runs outside the clock's tasks, such as a simulation.
    ///
    /// - Returns: The new time, or `nil` if nothing is asleep.
    func fireNextDeadline() -> Instant? {
        let (now, due) = state.withLock { state -> (Swift.Duration, [Sleeper]) in
            guard let earliest = state.earliestDeadline() else { return (state.now, []) }
            let due = state.takeEarliest(upTo: earliest)
            return (state.now, due)
        }
        if due.isEmpty { return nil }
        for sleeper in due { sleeper.continuation.resume() }
        return Instant(offset: now)
    }

    /// Wakes every sleeper at once with `CancellationError`, whatever its
    /// deadline, without moving time: for a simulation unwinding what a
    /// finished run left asleep.
    ///
    /// - Returns: How many were woken.
    @discardableResult
    func cancelAllSleepers() -> Int {
        let all = state.withLock { state -> [Sleeper] in
            let all = state.sleepers.values.sorted { $0.id < $1.id }
            state.sleepers = [:]
            state.deadlines = DeadlineHeap()
            return all
        }
        for sleeper in all { sleeper.continuation.resume(throwing: CancellationError()) }
        return all.count
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

    /// Suspends until at least `count` tasks are asleep on this clock *right
    /// now*, then returns.
    ///
    /// "At least, now" is the whole meaning, and it is a trap after an
    /// ``advance(by:)``: a task that has been woken and not yet gone back to
    /// sleep is not counted, but a different sleeper that was never woken is,
    /// so `waitForSleepers(count: 1)` can return at once for a sleeper that is
    /// not the one the test means. To wait for a sleep that starts after a
    /// point in the test, use ``waitForSleepers(newerThan:count:timeout:sourceLocation:)``.
    ///
    /// It never waits forever. A sleeper that never comes is a test that is
    /// wrong (the code under test is not using this clock, or has already
    /// finished) and the cheap way to find out is a message, not a time limit
    /// a minute later: after `timeout` of *real* time, or when the waiting
    /// task is cancelled, it records an issue that prints the clock's state —
    /// the time, every sleeper's deadline, and how many were asked for — and
    /// returns. A timeout also ends every sleep on the clock, now and later,
    /// with `CancellationError`: the test has failed, and a test that went on
    /// to await work parked on a clock nobody will move would hang the whole
    /// run, where this fails one test.
    ///
    /// - Parameters:
    ///   - count: How many sleepers must be asleep at once.
    ///   - timeout: How long to wait, in real time; `nil` waits until the
    ///     task is cancelled.
    ///   - sourceLocation: Where an issue is reported.
    public func waitForSleepers(
        count: Int = 1,
        timeout: Swift.Duration? = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await wait(
            for: .asleep(count), timeout: timeout, sourceLocation: sourceLocation,
            asked: "waitForSleepers(count: \(count))", needs: "at least \(count) asleep at once"
        )
    }

    /// Suspends until at least `count` sleeps have *started* since
    /// ``totalSleeps`` read `sleeps`, however long each lasts.
    ///
    /// For the sleep that follows an ``advance(by:)``: a retrying task wakes,
    /// fails, and sleeps again, and the test has to know that the second
    /// sleep is the one it is about to advance past, not the first, still
    /// counted a moment ago. Take the mark before advancing.
    ///
    ///     let mark = clock.totalSleeps
    ///     await clock.advance(by: .seconds(30))        // wakes the first backoff
    ///     await clock.waitForSleepers(newerThan: mark)  // the second has begun
    ///
    /// Reports a timeout or cancellation as ``waitForSleepers(count:timeout:sourceLocation:)``
    /// does.
    public func waitForSleepers(
        newerThan sleeps: Int,
        count: Int = 1,
        timeout: Swift.Duration? = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await wait(
            for: .totalSleeps(sleeps + count), timeout: timeout, sourceLocation: sourceLocation,
            asked: "waitForSleepers(newerThan: \(sleeps), count: \(count))", needs: "at least \(count) sleep(s) to have started since the mark of \(sleeps)"
        )
    }

    /// The clock's state in words, for a failure message: the time, every
    /// sleeper's deadline and how long until it, and the number of sleeps so far.
    public var summary: String {
        state.withLock { state in
            let sleepers = state.sleepers.values.sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
            var text = "TestClock now +\(state.now), \(sleepers.count) asleep"
            if !sleepers.isEmpty {
                text += ": " + sleepers.map { "wakes at +\($0.deadline) (in \($0.deadline - state.now))" }.joined(separator: "; ")
            }
            return text + "; \(state.totalSleeps) sleep(s) begun in all"
        }
    }

    private func wait(
        for target: Target, timeout: Swift.Duration?, sourceLocation: SourceLocation, asked: String, needs: String
    ) async {
        // The clock already gave up on this test: the issue is recorded.
        if state.withLock({ $0.aborted }) { return }
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            return state.nextID
        }
        let timer = timeout.map { timeout in
            DispatchWorkItem { [self] in
                let waiter = state.withLock { state -> CountWaiter? in
                    guard let index = state.countWaiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.countWaiters.remove(at: index)
                }
                waiter?.continuation.resume(returning: .timedOut)
            }
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitResult, Never>) in
                let immediate = state.withLock { state -> WaitResult? in
                    if state.isMet(target) { return .satisfied }
                    if Task.isCancelled { return .cancelled }
                    state.countWaiters.append(CountWaiter(id: id, target: target, continuation: continuation))
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                } else if let timer, let timeout {
                    // stoic:allow(sleep-for-timeout): a real-time safety net for a test that waits on a clock nobody advances; it only reports, and the test owns the wait
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout.dispatchInterval, execute: timer)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CountWaiter? in
                guard let index = state.countWaiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.countWaiters.remove(at: index)
            }
            waiter?.continuation.resume(returning: .cancelled)
        }
        timer?.cancel()
        switch result {
        case .satisfied:
            return
        case .timedOut, .cancelled:
            let why = result == .timedOut
                ? "gave up after \(timeout.map { "\($0)" } ?? "its timeout") of real time"
                : "was cancelled while waiting"
            Issue.record(
                """
                \(asked) \(why); it needs \(needs). \(summary).
                Either the code under test is not sleeping on this clock (it must take it from Ambient, or as a clock: parameter), \
                it has already finished or been woken (an earlier advance), or the sleeper is on another clock. \
                waitForSleepers(count:) counts sleepers asleep now; after an advance that wakes tasks, take `let mark = clock.totalSleeps` first \
                and wait with waitForSleepers(newerThan: mark).
                """,
                sourceLocation: sourceLocation
            )
            if result == .timedOut {
                state.withLock { $0.aborted = true }
                cancelAllSleepers()
            }
        }
    }

    private func yieldRepeatedly() async {
        for _ in 0..<64 { await Task.yield() }
    }
}

/// A binary min-heap of (deadline, id), ordered by deadline and then by the
/// order the sleepers went to sleep.
private struct DeadlineHeap {
    private var items: [(deadline: Swift.Duration, id: UInt64)] = []

    init() {}

    init(_ entries: [(Swift.Duration, UInt64)]) {
        items = entries.map { (deadline: $0.0, id: $0.1) }
        var index = items.count / 2 - 1
        while index >= 0 {
            siftDown(index)
            index -= 1
        }
    }

    var count: Int { items.count }
    var top: (deadline: Swift.Duration, id: UInt64)? { items.first }

    mutating func push(deadline: Swift.Duration, id: UInt64) {
        items.append((deadline, id))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(items[child], items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() {
        guard !items.isEmpty else { return }
        items.swapAt(0, items.count - 1)
        items.removeLast()
        siftDown(0)
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1, right = left + 1
            var smallest = parent
            if left < items.count, precedes(items[left], items[smallest]) { smallest = left }
            if right < items.count, precedes(items[right], items[smallest]) { smallest = right }
            if smallest == parent { return }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }

    private func precedes(_ a: (deadline: Swift.Duration, id: UInt64), _ b: (deadline: Swift.Duration, id: UInt64)) -> Bool {
        a.deadline != b.deadline ? a.deadline < b.deadline : a.id < b.id
    }
}

extension Swift.Duration {
    /// This duration as a Dispatch interval, capped at a day so a huge
    /// timeout cannot overflow.
    fileprivate var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        let nanoseconds = Int(min(max(seconds, 0), 86_400)) * 1_000_000_000 + Int(max(attoseconds, 0) / 1_000_000_000)
        return .nanoseconds(nanoseconds)
    }
}
