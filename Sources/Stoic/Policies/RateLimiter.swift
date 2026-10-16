internal import Synchronization

/// Keeps a caller inside the rate a service will accept, with a token bucket.
///
/// The bucket holds up to `burst` permits and is refilled at `rate` permits
/// per `interval`; it starts full, so a quiet app can send a burst and then
/// settles to the steady rate. ``acquire(permits:)`` waits for permits when
/// there are none, ``tryAcquire(permits:)`` never waits, and
/// ``execute(_:)`` is `acquire` followed by the operation.
///
/// **Waiting is first in, first out and bounded.** A task that must wait
/// queues behind the tasks already waiting, and a newcomer never overtakes
/// them, not even through ``tryAcquire(permits:)``. Before queuing, `acquire`
/// works out when it would be served, and refuses at once with
/// ``Rejection/Reason/rateLimited`` — carrying that wait as `retryAfter`,
/// so the caller can decide what to do instead of waiting — if the wait would
/// outlive ``Deadline/current``, or the queue already holds `queueLimit`
/// tasks. A task that is cancelled while queued, or whose enclosing deadline
/// cancels it, leaves without taking any permits: it is the waiter pattern of
/// ``AsyncSemaphore``, including the bookkeeping for a cancellation that
/// arrives before the waiter has queued, with a timer where the semaphore has
/// a release.
///
/// **The arithmetic is exact.** Credit is an integer counted in units of
/// "permit × interval-attoseconds", so a refill is `elapsed-attoseconds × rate`
/// with no division and no rounding, and the only division, for the time to
/// afford a request, rounds up. Over any schedule the permits granted by time
/// `t` are at most `burst + rate × t`, and a limiter with enough demand
/// grants exactly that. Refill is computed lazily from the elapsed time on
/// the limiter's clock; nothing ticks and no task is running while it is idle.
///
/// Permits are spent, not leased: an operation that fails does not get its
/// permit back, because the server counted the attempt.
///
///     let limiter = RateLimiter(rate: 50, per: .seconds(1), burst: 100, label: "api")
///     let reply = try await limiter.execute { try await client.send(request) }
public final class RateLimiter: Policy, CustomStringConvertible {
    /// Names the limiter in rejections and events.
    public let label: String

    /// Permits added per ``interval``.
    public let rate: Int

    /// The period `rate` is measured over.
    public let interval: Duration

    /// The most permits the bucket can hold.
    public let burst: Int

    /// The most tasks allowed to wait; `nil` for no limit beyond cancellation
    /// and deadlines.
    public let queueLimit: Int?

    private let clock: AnyClock
    // Credit units in one permit: the interval in attoseconds. A refill of
    // `d` attoseconds adds `d × rate` units, exactly.
    private let unit: Int128
    private let capacity: Int128

    private struct Waiter {
        let id: UInt64
        let cost: Int128
        // Set while the waiter is parked behind others, so it can be woken
        // when it reaches the head or leaves.
        var continuation: CheckedContinuation<Void, Never>?
    }

    private struct State {
        var credit: Int128
        var refilledAt: AnyClock.Instant
        var nextID: UInt64 = 0
        var queue: [Waiter] = []
        // The cost of everyone in `queue`, kept so that an arrival can work
        // out its wait without walking the queue.
        var queuedCost: Int128 = 0
        // Waiters that were removed by a cancellation, with the reason, until
        // the waiter's own task collects it.
        var departed: [UInt64: Rejection] = [:]
    }

    private let state: Mutex<State>

    /// A limiter that allows `rate` permits per `interval`.
    ///
    /// - Parameters:
    ///   - rate: Permits added to the bucket per `interval`. At least 1.
    ///   - interval: The period the rate is measured over. Positive.
    ///   - burst: The bucket's size; by default `rate`, one interval's worth.
    ///   - queueLimit: The most tasks that may wait for permits (default 100),
    ///     or `nil` to let any number wait. A task that cannot be served
    ///     beyond this is rejected at once, which is usually what an
    ///     overloaded caller wants.
    ///   - label: Names the limiter in events.
    ///   - clock: The clock to measure time on; by default the ambient clock
    ///     when the limiter is created. A limiter measures time on one clock
    ///     for its whole life, so one in a `static let` keeps the clock of
    ///     its first use, a test's virtual clock included (see
    ///     ``CircuitBreaker/init(label:_:clock:fileID:line:)``).
    public init(
        rate: Int,
        per interval: Duration = .seconds(1),
        burst: Int? = nil,
        queueLimit: Int? = 100,
        label: String,
        clock: AnyClock? = nil
    ) {
        precondition(rate >= 1, "a rate limiter needs a rate of at least one permit")
        precondition(interval > .zero, "a rate limiter's interval must be positive")
        let burst = burst ?? rate
        precondition(burst >= 1, "a rate limiter's burst must be at least one permit")
        precondition(queueLimit.map { $0 >= 0 } ?? true, "a rate limiter's queue cannot have a negative size")
        let unit = interval.attoseconds
        let (capacity, overflow) = unit.multipliedReportingOverflow(by: Int128(burst))
        precondition(!overflow, "a rate limiter's burst times its interval is too large to count exactly")
        let (_, rateOverflow) = unit.multipliedReportingOverflow(by: Int128(rate))
        precondition(!rateOverflow, "a rate limiter's rate times its interval is too large to count exactly")
        let clock = clock ?? Ambient.current.clock
        self.label = label
        self.rate = rate
        self.interval = interval
        self.burst = burst
        self.queueLimit = queueLimit
        self.clock = clock
        self.unit = unit
        self.capacity = capacity
        self.state = Mutex(State(credit: capacity, refilledAt: clock.now))
    }

    /// Whole permits in the bucket right now.
    public var availablePermits: Int {
        let now = clock.now
        return state.withLock { state in
            refill(&state, now: now)
            return Int(clamping: state.credit / unit)
        }
    }

    /// Tasks waiting for permits right now.
    public var waiterCount: Int {
        state.withLock { $0.queue.count }
    }

    /// Takes `permits` if the bucket holds them and nobody is waiting;
    /// otherwise takes nothing and returns `false`.
    ///
    /// Never waits, and never overtakes a waiter.
    public func tryAcquire(permits: Int = 1) -> Bool {
        precondition(permits >= 1, "ask for at least one permit")
        guard permits <= burst else { return false }
        let cost = Int128(permits) * unit
        let now = clock.now
        return state.withLock { state in
            refill(&state, now: now)
            guard state.queue.isEmpty, state.credit >= cost else { return false }
            state.credit -= cost
            return true
        }
    }

    /// Takes `permits`, waiting for them if necessary.
    ///
    /// - Throws: A ``Rejection``: `.rateLimited` when the wait would outlive
    ///   ``Deadline/current`` or the queue is full (with `retryAfter` set to
    ///   the wait), or when `permits` exceeds `burst` and could never be
    ///   served; `.cancelled` when the task was cancelled; `.deadlineExceeded`
    ///   when the deadline had passed or passed while waiting. In every case
    ///   no permits were taken.
    public nonisolated(nonsending) func acquire(permits: Int = 1) async throws(Rejection) {
        precondition(permits >= 1, "ask for at least one permit")
        if let refusal = Rejection.refusedBeforeStart(label: label) {
            report(refusal.reason.rawValue, permits: permits, retryAfter: nil)
            throw refusal
        }
        guard permits <= burst else {
            Ambient.record(Event("ratelimiter.oversized", level: .warning, label: label, fields: [
                .init("permits", .int(permits)),
                .init("burst", .int(burst)),
            ]))
            throw Rejection(.rateLimited, label: label)
        }
        let cost = Int128(permits) * unit
        let deadline = Deadline.current
        let arrival = clock.now

        enum Admission {
            case granted
            case refused(Rejection, why: String)
            case queued(UInt64)
        }
        let admission = state.withLock { state -> Admission in
            refill(&state, now: arrival)
            if state.queue.isEmpty, state.credit >= cost {
                state.credit -= cost
                return .granted
            }
            // When would I be served? After everyone ahead, and me.
            let needed = state.queuedCost + cost - state.credit
            let wait = timeToEarn(needed)
            if let queueLimit, state.queue.count >= queueLimit {
                return .refused(Rejection(.rateLimited, label: label, retryAfter: wait), why: "queue_full")
            }
            if let deadline, wait > deadline.remaining {
                return .refused(Rejection(.rateLimited, label: label, retryAfter: wait), why: "would_exceed_deadline")
            }
            let id = state.nextID
            state.nextID += 1
            state.queue.append(Waiter(id: id, cost: cost))
            state.queuedCost += cost
            return .queued(id)
        }

        switch admission {
        case .granted:
            return
        case .refused(let rejection, let why):
            report(why, permits: permits, retryAfter: rejection.retryAfter)
            throw rejection
        case .queued(let id):
            let outcome = await withTaskCancellationHandler {
                await waitForTurn(id)
            } onCancel: {
                leave(id, because: Rejection(.cancelled, label: label))
            }
            if let outcome {
                let rejection = outcome.attributingDeadline()
                report(rejection.reason.rawValue, permits: permits, retryAfter: nil)
                throw rejection
            }
            Ambient.record(Event("ratelimiter.waited", level: .debug, label: label, fields: [
                .init("permits", .int(permits)),
                .init("waited", .duration(arrival.duration(to: clock.now))),
            ]))
        }
    }

    /// Runs `operation` once a permit is available.
    ///
    /// - Throws: `.failed` with the operation's error, or `.rejected` with
    ///   why ``acquire(permits:)`` refused. A failed operation keeps its
    ///   permit spent.
    public nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        do throws(Rejection) {
            try await acquire(permits: 1)
        } catch {
            throw .rejected(error)
        }
        // Time waiting for a permit is not the dependency's: a breaker
        // outside measures from now.
        DispatchMark.dispatched()
        do throws(Failure) {
            return try await operation()
        } catch {
            throw .failed(error)
        }
    }

    // MARK: - Waiting

    private enum Step {
        case granted(CheckedContinuation<Void, Never>?)
        case rejected(Rejection)
        case sleep(Duration)
        case park
    }

    /// Waits until waiter `id` has been served (`nil`) or has left (why).
    ///
    /// The waiter at the head of the queue is the only one that sleeps. It
    /// recomputes what it still needs each time it wakes, so a late wake-up,
    /// or a waiter ahead of it leaving, can never cost tokens or grant ones
    /// that were not earned; everyone else parks until they reach the head.
    private nonisolated(nonsending) func waitForTurn(_ id: UInt64) async -> Rejection? {
        while true {
            let now = clock.now
            let step = state.withLock { state -> Step in
                if let rejection = state.departed.removeValue(forKey: id) {
                    return .rejected(rejection)
                }
                guard let index = state.queue.firstIndex(where: { $0.id == id }) else {
                    // Neither queued nor departed: cannot happen, but a waiter
                    // must never wait on nothing.
                    return .rejected(Rejection(.cancelled, label: label))
                }
                guard index == 0 else { return .park }
                refill(&state, now: now)
                let cost = state.queue[0].cost
                guard state.credit >= cost else {
                    return .sleep(timeToEarn(cost - state.credit))
                }
                state.credit -= cost
                state.queue.removeFirst()
                state.queuedCost -= cost
                return .granted(takeHeadContinuation(&state))
            }
            switch step {
            case .granted(let next):
                next?.resume()
                return nil
            case .rejected(let rejection):
                return rejection
            case .sleep(let wait):
                do {
                    try await clock.sleep(until: now.advanced(by: wait), tolerance: nil)
                } catch {  // stoic:allow(swallowed-cancellation): turned into a rejection the next turn returns
                    // Cancelled while sleeping: the cancellation handler is
                    // removing this waiter; collect that on the next turn.
                    leave(id, because: Rejection(.cancelled, label: label))
                }
            case .park:
                await park(id)
            }
        }
    }

    /// Suspends waiter `id` until it reaches the head of the queue or leaves.
    private nonisolated(nonsending) func park(_ id: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.departed[id] != nil { return true }
                guard let index = state.queue.firstIndex(where: { $0.id == id }) else { return true }
                if index == 0 { return true }
                state.queue[index].continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Takes waiter `id` out of the queue, if it is still waiting, and wakes
    /// whoever that changes the head for.
    private func leave(_ id: UInt64, because rejection: Rejection) {
        let wake = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard let index = state.queue.firstIndex(where: { $0.id == id }) else {
                // Already served, or already gone: nothing to take back.
                return []
            }
            let removed = state.queue.remove(at: index)
            state.queuedCost -= removed.cost
            state.departed[id] = rejection
            var wake: [CheckedContinuation<Void, Never>] = []
            if let own = removed.continuation { wake.append(own) }
            if index == 0, let next = takeHeadContinuation(&state) { wake.append(next) }
            return wake
        }
        for continuation in wake { continuation.resume() }
    }

    /// The parked continuation of the waiter now at the head, if it is parked.
    private func takeHeadContinuation(_ state: inout State) -> CheckedContinuation<Void, Never>? {
        guard !state.queue.isEmpty else { return nil }
        return state.queue[0].continuation.take()
    }

    // MARK: - Arithmetic

    /// Adds what has been earned since the last refill, up to the bucket's size.
    private func refill(_ state: inout State, now: AnyClock.Instant) {
        let elapsed = state.refilledAt.duration(to: now)
        guard elapsed > .zero else { return }
        state.refilledAt = now
        let (gain, gainOverflow) = elapsed.attoseconds.multipliedReportingOverflow(by: Int128(rate))
        let (sum, sumOverflow) = state.credit.addingReportingOverflow(gain)
        state.credit = (gainOverflow || sumOverflow) ? capacity : min(capacity, sum)
    }

    /// How long until `deficit` credit units have been earned, rounded up.
    private func timeToEarn(_ deficit: Int128) -> Duration {
        guard deficit > 0 else { return .zero }
        let rate = Int128(rate)
        let (padded, overflow) = deficit.addingReportingOverflow(rate - 1)
        let attoseconds = overflow ? deficit / rate : padded / rate
        return Duration(attoseconds: attoseconds)
    }

    private func report(_ reason: String, permits: Int, retryAfter: Duration?) {
        var fields: [Event.Field] = [
            .init("reason", .string(reason), privacy: .public),
            .init("permits", .int(permits)),
        ]
        if let retryAfter { fields.append(.init("retry_after", .duration(retryAfter))) }
        Ambient.record(Event("ratelimiter.rejected", level: .info, label: label, fields: fields))
    }

    public var description: String {
        "RateLimiter(\(label): \(rate) per \(interval), burst \(burst), \(availablePermits) available, \(waiterCount) waiting)"
    }
}
