/// A policy for when to try again: how long to wait before each retry, and
/// when to stop.
///
/// A schedule is data, not code. It can be printed, compared, inspected for
/// its worst case, and stepped deterministically in a test. Retry delays are
/// numbered from one: delay 1 is the wait before the second attempt.
///
///     Schedule.exponential(base: .milliseconds(200)).jittered().attempts(5)
///
/// A schedule that may go on forever is a `Schedule`; one with a fixed
/// maximum number of attempts is a ``BoundedSchedule``. ``retry(_:budget:classify:nesting:label:fileID:line:operation:)``
/// takes only the bounded kind, so an unbounded retry is a compile error,
/// not a production incident.
public struct Schedule: Sendable, Hashable, CustomStringConvertible {
    indirect enum Node: Sendable, Hashable {
        case fixed(Duration)
        case linear(Duration)
        case exponential(base: Duration, factor: Double)
        case fibonacci(Duration)
        case delays([Duration])
        case decorrelated(base: Duration, cap: Duration)
        case capped(Node, Duration)
        case defaultCap(Node, Duration)
        case jittered(Node, Jitter)
        case defaultJitter(Node)
        case attempts(Node, Int)
        case elapsed(Node, Duration)
        case union(Node, Node)
        case intersection(Node, Node)
        case andThen(Node, Node)
    }

    let node: Node

    init(_ node: Node) {
        self.node = node
    }

    // MARK: Bases

    /// The same delay before every retry.
    public static func fixed(_ delay: Duration) -> Schedule {
        Schedule(.fixed(delay.clampedNonNegative))
    }

    /// No delay at all. Rarely right on its own: combine it with a bound.
    public static let immediate = Schedule(.fixed(.zero))

    /// `base × n` before retry n.
    public static func linear(_ base: Duration) -> Schedule {
        Schedule(.linear(base.clampedNonNegative))
    }

    /// `base × factor^(n−1)` before retry n.
    ///
    /// Safe by default: capped at five minutes and fully jittered, as AWS
    /// recommends, unless ``capped(at:)`` or ``jittered(_:)`` (or
    /// ``unjittered()``) says otherwise. A factor below one is treated as one:
    /// a backoff that shrinks is not a backoff.
    public static func exponential(base: Duration, factor: Double = 2) -> Schedule {
        let factor = factor.isNaN ? 1 : max(1, factor)
        return Schedule(.defaultJitter(.defaultCap(.exponential(base: base.clampedNonNegative, factor: factor), .seconds(300))))
    }

    /// Fibonacci multiples of `base`; capped at five minutes and fully
    /// jittered unless told otherwise, like ``exponential(base:factor:)``.
    public static func fibonacci(_ base: Duration) -> Schedule {
        Schedule(.defaultJitter(.defaultCap(.fibonacci(base.clampedNonNegative), .seconds(300))))
    }

    /// Exactly these delays, then stop. Bounded by its own length.
    public static func delays(_ delays: [Duration]) -> BoundedSchedule {
        BoundedSchedule(Schedule(.attempts(.delays(delays.map(\.clampedNonNegative)), delays.count + 1)))
    }

    /// AWS's decorrelated jitter: each delay is random in
    /// `base ... previous × 3`, never above `cap`. Good for long tails.
    public static func decorrelated(base: Duration, cap: Duration) -> Schedule {
        Schedule(.decorrelated(base: base.clampedNonNegative, cap: max(base, cap)))
    }

    // MARK: Shape

    /// No delay longer than `maximum`.
    ///
    /// Replaces a base's *default* cap (so `.exponential(…).capped(at: .hours(1))`
    /// can raise the five-minute default), and otherwise only ever tightens:
    /// capping twice keeps the smaller cap.
    public func capped(at maximum: Duration) -> Schedule {
        let maximum = maximum.clampedNonNegative
        if let replaced = node.replacingDefaultCap(with: maximum) {
            return Schedule(replaced)
        }
        if case .capped(let inner, let existing) = node {
            return Schedule(.capped(inner, min(existing, maximum)))
        }
        return Schedule(.capped(node, maximum))
    }

    /// Randomises each delay. Full jitter, the default, draws uniformly from
    /// zero to the delay; it never lengthens a delay, so a cap still holds.
    /// Replaces a base's default jitter.
    public func jittered(_ jitter: Jitter = .full) -> Schedule {
        if let replaced = node.replacingDefaultJitter(with: jitter) {
            return Schedule(replaced)
        }
        return Schedule(.jittered(node, jitter))
    }

    /// Removes randomness, including a base's default jitter: for tests and
    /// for the rare delay that must be exact.
    public func unjittered() -> Schedule {
        jittered(.none)
    }

    /// Stops once `duration` has elapsed since the first attempt. On its own
    /// this does not bound the number of attempts: a schedule with no delay
    /// could still spin. Add ``attempts(_:)`` for that.
    public func upTo(elapsed duration: Duration) -> Schedule {
        Schedule(.elapsed(node, duration.clampedNonNegative))
    }

    /// At most `count` attempts in all — the first plus `count − 1` retries.
    public func attempts(_ count: Int) -> BoundedSchedule {
        precondition(count >= 1, "a schedule needs at least one attempt")
        return BoundedSchedule(Schedule(.attempts(node, count)))
    }

    /// Continues while either schedule continues, with the shorter delay.
    public func union(_ other: Schedule) -> Schedule {
        Schedule(.union(node, other.node))
    }

    /// Continues while both schedules continue, with the longer delay.
    public func intersection(_ other: Schedule) -> Schedule {
        Schedule(.intersection(node, other.node))
    }

    /// Follows `self` until it stops, then `next`, counting `next`'s retries from one.
    public func andThen(_ next: Schedule) -> Schedule {
        Schedule(.andThen(node, next.node))
    }

    // MARK: Stepping

    /// A fresh stepper over this schedule.
    public func makeStepper(random: RandomGenerator) -> Stepper {
        Stepper(node: node, random: random)
    }

    /// The delays the schedule would choose with jitter at its maximum, up
    /// to `limit` retries — for documentation and tests.
    public func maximalDelays(limit: Int) -> [Duration] {
        var stepper = Stepper(node: node, random: nil)
        var delays: [Duration] = []
        var elapsed = Duration.zero
        while delays.count < limit, let delay = stepper.next(elapsed: elapsed) {
            delays.append(delay)
            elapsed = elapsed.saturatingAdding(delay)
        }
        return delays
    }

    public var description: String { node.description }

    /// Steps a schedule one retry at a time.
    public struct Stepper: Sendable {
        private var state: StepState
        private var random: RandomGenerator?

        init(node: Node, random: RandomGenerator?) {
            self.state = StepState(node)
            self.random = random
        }

        /// The delay before the next retry, or `nil` to stop.
        ///
        /// - Parameter elapsed: Time since the first attempt began.
        public mutating func next(elapsed: Duration) -> Duration? {
            state.next(elapsed: elapsed, random: &random)
        }
    }
}

/// A schedule with a fixed maximum number of attempts.
///
/// The only kind ``retry(_:budget:classify:nesting:label:fileID:line:operation:)`` accepts. Its worst case is computable.
public struct BoundedSchedule: Sendable, Hashable, CustomStringConvertible {
    /// The underlying schedule.
    public let schedule: Schedule

    init(_ schedule: Schedule) {
        self.schedule = schedule
    }

    /// The most attempts the schedule allows, first attempt included.
    ///
    /// Computed from the schedule's structure, so it is a true upper bound:
    /// an elapsed-time limit never lowers it, because jitter can fit more
    /// attempts under that limit than maximal delays would.
    public var maximumAttempts: Int {
        schedule.node.attemptLimit ?? .max
    }

    /// The longest total time the schedule can spend waiting between
    /// attempts: every delay at its maximum (jitter excluded), ignoring
    /// elapsed-time limits.
    public var maximumTotalDelay: Duration {
        let retries = maximumAttempts - 1
        var stepper = Schedule.Stepper(node: schedule.node.removingElapsedLimits, random: nil)
        var total = Duration.zero
        var longest = Duration.zero
        let exact = min(retries, 100_000)
        for _ in 0..<exact {
            guard let delay = stepper.next(elapsed: .zero) else { return total }
            total = total.saturatingAdding(delay)
            longest = max(longest, delay)
        }
        // Beyond 100,000 retries, bound the rest by the longest delay seen
        // rather than step them all.
        return total.saturatingAdding(longest.saturatingMultiplied(by: Double(retries - exact)))
    }

    /// The longest a retry under this schedule can take, if each attempt is
    /// bounded by `attemptTimeout`: every attempt timing out, every delay at
    /// its maximum. A `retryAfter` decision may replace a delay with up to
    /// five minutes, which this bound does not include.
    public func worstCase(attemptTimeout: Duration) -> Duration {
        attemptTimeout
            .saturatingMultiplied(by: Double(maximumAttempts))
            .saturatingAdding(maximumTotalDelay)
    }

    public func capped(at maximum: Duration) -> BoundedSchedule {
        BoundedSchedule(schedule.capped(at: maximum))
    }

    public func jittered(_ jitter: Jitter = .full) -> BoundedSchedule {
        BoundedSchedule(schedule.jittered(jitter))
    }

    public func upTo(elapsed duration: Duration) -> BoundedSchedule {
        BoundedSchedule(schedule.upTo(elapsed: duration))
    }

    public func attempts(_ count: Int) -> BoundedSchedule {
        schedule.attempts(count)
    }

    /// Continues while either continues; bounded because both are.
    public func union(_ other: BoundedSchedule) -> BoundedSchedule {
        BoundedSchedule(schedule.union(other.schedule))
    }

    /// Continues while both continue; bounded because `self` is.
    public func intersection(_ other: Schedule) -> BoundedSchedule {
        BoundedSchedule(schedule.intersection(other))
    }

    /// `self`, then `next`; bounded because both are.
    public func andThen(_ next: BoundedSchedule) -> BoundedSchedule {
        BoundedSchedule(schedule.andThen(next.schedule))
    }

    public func makeStepper(random: RandomGenerator) -> Schedule.Stepper {
        schedule.makeStepper(random: random)
    }

    public var description: String { schedule.description }
}

/// How a schedule randomises its delays.
public enum Jitter: Sendable, Hashable, CustomStringConvertible {
    /// Uniform in `0 ... delay`. AWS's recommendation, and the default.
    case full
    /// Uniform in `delay/2 ... delay`: keeps a floor under each wait.
    case equal
    /// No randomness.
    case none

    public var description: String {
        switch self {
        case .full: "full"
        case .equal: "equal"
        case .none: "none"
        }
    }
}

// MARK: - Interpretation

/// The mutable state of one walk through a schedule tree.
private indirect enum StepState: Sendable {
    case fixed(Duration)
    case linear(Duration, retry: Int)
    case exponential(base: Duration, factor: Double, retry: Int)
    case fibonacci(Duration, previous: Duration, current: Duration)
    case delays([Duration], retry: Int)
    case decorrelated(base: Duration, cap: Duration, previous: Duration)
    case capped(StepState, Duration)
    case jittered(StepState, Jitter)
    case attempts(StepState, limit: Int, retry: Int)
    case elapsed(StepState, Duration)
    case union(StepState, StepState, leftDone: Bool, rightDone: Bool)
    case intersection(StepState, StepState)
    case andThen(StepState, StepState, onSecond: Bool, offset: Duration)

    init(_ node: Schedule.Node) {
        switch node {
        case .fixed(let delay): self = .fixed(delay)
        case .linear(let base): self = .linear(base, retry: 0)
        case .exponential(let base, let factor): self = .exponential(base: base, factor: factor, retry: 0)
        case .fibonacci(let base): self = .fibonacci(base, previous: .zero, current: base)
        case .delays(let delays): self = .delays(delays, retry: 0)
        case .decorrelated(let base, let cap): self = .decorrelated(base: base, cap: cap, previous: base)
        case .capped(let inner, let cap), .defaultCap(let inner, let cap): self = .capped(StepState(inner), cap)
        case .jittered(let inner, let jitter): self = .jittered(StepState(inner), jitter)
        case .defaultJitter(let inner): self = .jittered(StepState(inner), .full)
        case .attempts(let inner, let limit): self = .attempts(StepState(inner), limit: limit, retry: 0)
        case .elapsed(let inner, let limit): self = .elapsed(StepState(inner), limit)
        case .union(let left, let right): self = .union(StepState(left), StepState(right), leftDone: false, rightDone: false)
        case .intersection(let left, let right): self = .intersection(StepState(left), StepState(right))
        case .andThen(let first, let second): self = .andThen(StepState(first), StepState(second), onSecond: false, offset: .zero)
        }
    }

    /// `random == nil` means "jitter at its maximum": the deterministic upper bound.
    mutating func next(elapsed: Duration, random: inout RandomGenerator?) -> Duration? {
        switch self {
        case .fixed(let delay):
            return delay

        case .linear(let base, let retry):
            self = .linear(base, retry: retry + 1)
            return base.saturatingMultiplied(by: Double(retry + 1))

        case .exponential(let base, let factor, let retry):
            self = .exponential(base: base, factor: factor, retry: retry + 1)
            return base.saturatingMultiplied(by: pow(factor, retry))

        case .fibonacci(let base, let previous, let current):
            self = .fibonacci(base, previous: current, current: current.saturatingAdding(previous))
            return current

        case .delays(let delays, let retry):
            guard retry < delays.count else { return nil }
            self = .delays(delays, retry: retry + 1)
            return delays[retry]

        case .decorrelated(let base, let cap, let previous):
            let upper = min(cap, previous.saturatingMultiplied(by: 3))
            let delay: Duration
            if random == nil {
                delay = upper
            } else {
                delay = uniform(from: base, to: max(base, upper), random: &random)
            }
            self = .decorrelated(base: base, cap: cap, previous: delay)
            return delay

        case .capped(var inner, let cap):
            let delay = inner.next(elapsed: elapsed, random: &random)
            self = .capped(inner, cap)
            return delay.map { min($0, cap) }

        case .jittered(var inner, let jitter):
            let delay = inner.next(elapsed: elapsed, random: &random)
            self = .jittered(inner, jitter)
            guard let delay else { return nil }
            guard random != nil else { return delay }
            switch jitter {
            case .full: return uniform(from: .zero, to: delay, random: &random)
            case .equal: return uniform(from: delay.saturatingMultiplied(by: 0.5), to: delay, random: &random)
            case .none: return delay
            }

        case .attempts(var inner, let limit, let retry):
            guard retry + 1 < limit else { return nil }
            let delay = inner.next(elapsed: elapsed, random: &random)
            self = .attempts(inner, limit: limit, retry: retry + 1)
            return delay

        case .elapsed(var inner, let limit):
            guard elapsed < limit else { return nil }
            let delay = inner.next(elapsed: elapsed, random: &random)
            self = .elapsed(inner, limit)
            return delay

        case .union(var left, var right, var leftDone, var rightDone):
            let l = leftDone ? nil : left.next(elapsed: elapsed, random: &random)
            let r = rightDone ? nil : right.next(elapsed: elapsed, random: &random)
            leftDone = leftDone || l == nil
            rightDone = rightDone || r == nil
            self = .union(left, right, leftDone: leftDone, rightDone: rightDone)
            switch (l, r) {
            case (let l?, let r?): return min(l, r)
            case (let l?, nil): return l
            case (nil, let r?): return r
            case (nil, nil): return nil
            }

        case .intersection(var left, var right):
            let l = left.next(elapsed: elapsed, random: &random)
            let r = right.next(elapsed: elapsed, random: &random)
            self = .intersection(left, right)
            guard let l, let r else { return nil }
            return max(l, r)

        case .andThen(var first, var second, let onSecond, let offset):
            if !onSecond {
                if let delay = first.next(elapsed: elapsed, random: &random) {
                    self = .andThen(first, second, onSecond: false, offset: offset)
                    return delay
                }
                let delay = second.next(elapsed: .zero, random: &random)
                self = .andThen(first, second, onSecond: true, offset: elapsed)
                return delay
            }
            let delay = second.next(elapsed: elapsed.saturatingSubtracting(offset), random: &random)
            self = .andThen(first, second, onSecond: true, offset: offset)
            return delay
        }
    }
}

private func uniform(from lower: Duration, to upper: Duration, random: inout RandomGenerator?) -> Duration {
    guard upper > lower, random != nil else { return upper }
    let span = upper.attoseconds - lower.attoseconds
    let fraction = Double(random!.next() >> 11) / Double(UInt64(1) << 53)
    let offset = Int128(Double(span) * fraction)
    return Duration(attoseconds: lower.attoseconds + min(span, max(0, offset)))
}

private func pow(_ base: Double, _ exponent: Int) -> Double {
    // Repeated squaring, saturating to infinity (which saturatingMultiplied clamps).
    var result = 1.0
    var square = base
    var remaining = exponent
    while remaining > 0 {
        if remaining & 1 == 1 { result *= square }
        square *= square
        remaining >>= 1
        if result.isInfinite { return .infinity }
    }
    return result
}

extension Duration {
    fileprivate var clampedNonNegative: Duration { max(.zero, self) }
}

extension Schedule.Node: CustomStringConvertible {
    var description: String {
        switch self {
        case .fixed(let delay): "fixed(\(delay))"
        case .linear(let base): "linear(\(base))"
        case .exponential(let base, let factor): "exponential(\(base), ×\(factor))"
        case .fibonacci(let base): "fibonacci(\(base))"
        case .delays(let delays): "delays(\(delays.map(\.description).joined(separator: ", ")))"
        case .decorrelated(let base, let cap): "decorrelated(\(base)…\(cap))"
        case .capped(let inner, let cap): "\(inner).capped(\(cap))"
        case .defaultCap(let inner, let cap): "\(inner).capped(\(cap), default)"
        case .jittered(let inner, let jitter): "\(inner).jittered(\(jitter))"
        case .defaultJitter(let inner): "\(inner).jittered(full, default)"
        case .attempts(let inner, let count): "\(inner).attempts(\(count))"
        case .elapsed(let inner, let limit): "\(inner).upTo(\(limit))"
        case .union(let left, let right): "(\(left) ∪ \(right))"
        case .intersection(let left, let right): "(\(left) ∩ \(right))"
        case .andThen(let first, let second): "(\(first) then \(second))"
        }
    }
}

// The bases, reachable from a `BoundedSchedule` context so that a call site
// can write an implicit member chain:
//
//     try await retry(.exponential(base: .seconds(1)).jittered().attempts(5)) { … }
//
// Each returns an unbounded `Schedule`; the chain must end in a bound to
// type-check, which is the point.
extension BoundedSchedule {
    public static func fixed(_ delay: Duration) -> Schedule { Schedule.fixed(delay) }
    public static var immediate: Schedule { Schedule.immediate }
    public static func linear(_ base: Duration) -> Schedule { Schedule.linear(base) }
    public static func exponential(base: Duration, factor: Double = 2) -> Schedule { Schedule.exponential(base: base, factor: factor) }
    public static func fibonacci(_ base: Duration) -> Schedule { Schedule.fibonacci(base) }
    public static func decorrelated(base: Duration, cap: Duration) -> Schedule { Schedule.decorrelated(base: base, cap: cap) }
    public static func delays(_ delays: [Duration]) -> BoundedSchedule { Schedule.delays(delays) }
}

extension Schedule.Node {
    /// The most attempts this node allows, or `nil` when unbounded.
    var attemptLimit: Int? {
        switch self {
        case .fixed, .linear, .exponential, .fibonacci, .decorrelated:
            return nil
        case .delays(let delays):
            return delays.count + 1
        case .capped(let inner, _), .defaultCap(let inner, _), .jittered(let inner, _), .defaultJitter(let inner), .elapsed(let inner, _):
            return inner.attemptLimit
        case .attempts(let inner, let limit):
            return inner.attemptLimit.map { min($0, limit) } ?? limit
        case .union(let left, let right):
            guard let l = left.attemptLimit, let r = right.attemptLimit else { return nil }
            return max(l, r)
        case .intersection(let left, let right):
            switch (left.attemptLimit, right.attemptLimit) {
            case (let l?, let r?): return min(l, r)
            case (let l?, nil): return l
            case (nil, let r?): return r
            case (nil, nil): return nil
            }
        case .andThen(let first, let second):
            guard let f = first.attemptLimit, let s = second.attemptLimit else { return nil }
            let (sum, overflow) = (f - 1).addingReportingOverflow(s - 1)
            return overflow ? .max : sum + 1
        }
    }

    /// This node with every elapsed-time limit removed: for computing bounds.
    var removingElapsedLimits: Schedule.Node {
        switch self {
        case .fixed, .linear, .exponential, .fibonacci, .decorrelated, .delays: self
        case .capped(let inner, let cap): .capped(inner.removingElapsedLimits, cap)
        case .defaultCap(let inner, let cap): .defaultCap(inner.removingElapsedLimits, cap)
        case .jittered(let inner, let jitter): .jittered(inner.removingElapsedLimits, jitter)
        case .defaultJitter(let inner): .defaultJitter(inner.removingElapsedLimits)
        case .attempts(let inner, let limit): .attempts(inner.removingElapsedLimits, limit)
        case .elapsed(let inner, _): inner.removingElapsedLimits
        case .union(let l, let r): .union(l.removingElapsedLimits, r.removingElapsedLimits)
        case .intersection(let l, let r): .intersection(l.removingElapsedLimits, r.removingElapsedLimits)
        case .andThen(let a, let b): .andThen(a.removingElapsedLimits, b.removingElapsedLimits)
        }
    }

    /// This node with its default cap replaced, if its wrapper spine has one.
    func replacingDefaultCap(with cap: Duration) -> Schedule.Node? {
        switch self {
        case .defaultCap(let inner, _): .capped(inner, cap)
        case .defaultJitter(let inner): inner.replacingDefaultCap(with: cap).map { .defaultJitter($0) }
        case .jittered(let inner, let jitter): inner.replacingDefaultCap(with: cap).map { .jittered($0, jitter) }
        case .attempts(let inner, let limit): inner.replacingDefaultCap(with: cap).map { .attempts($0, limit) }
        case .elapsed(let inner, let limit): inner.replacingDefaultCap(with: cap).map { .elapsed($0, limit) }
        default: nil
        }
    }

    /// This node with its default jitter replaced, if its wrapper spine has one.
    func replacingDefaultJitter(with jitter: Jitter) -> Schedule.Node? {
        switch self {
        case .defaultJitter(let inner): .jittered(inner, jitter)
        case .capped(let inner, let cap): inner.replacingDefaultJitter(with: jitter).map { .capped($0, cap) }
        case .defaultCap(let inner, let cap): inner.replacingDefaultJitter(with: jitter).map { .defaultCap($0, cap) }
        case .attempts(let inner, let limit): inner.replacingDefaultJitter(with: jitter).map { .attempts($0, limit) }
        case .elapsed(let inner, let limit): inner.replacingDefaultJitter(with: jitter).map { .elapsed($0, limit) }
        default: nil
        }
    }
}
