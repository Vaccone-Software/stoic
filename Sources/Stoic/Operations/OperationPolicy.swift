/// Everything derived for one call of a declared operation: a value, so a
/// test can assert it and an event can print it.
///
/// ``Backend/Operation/policy(at:)`` builds it from the declaration, its
/// backend's kind and capacity, and the urgency, by the tables in
/// design/22 (The derivation). Nothing at a call site changes it; the
/// call's own deadline, when it has one, replaces ``deadline``.
///
///     let policy = Catalogue.episode.policy(at: .interactive)
///     #expect(policy.deadline == .seconds(10))
///     #expect(policy.schedule.maximumAttempts == 2)
public struct OperationPolicy: Sendable, Hashable, CustomStringConvertible {
    /// The urgency it was derived for, after the operation's ceiling.
    public let urgency: Urgency

    /// The total time for the call, every attempt and wait included, when
    /// the caller set no deadline of its own.
    public let deadline: Duration

    /// When to try again: exponential, fully jittered, capped; its attempts
    /// count the first.
    public let schedule: BoundedSchedule

    /// The most one attempt may take, or `nil` when an attempt is bounded by
    /// the deadline alone (a `local` or `compute` backend, or a `.long`
    /// operation).
    public let attemptTimeout: Duration?

    /// The breaker the backend gets, or `nil` for none (`local` and
    /// `compute` backends).
    public let breaker: BreakerPolicy?

    /// The slots of the backend's capacity that calls at this urgency *or
    /// lower* may hold together.
    public let admission: Int

    /// Writers a `local` backend admits at once, when this call is a writer
    /// (an operation that is not `.readOnly`); `nil` when it takes no writer
    /// lane.
    public let writers: Int?

    /// Whether delays stretch when the device struggles (hot, low power,
    /// short of memory): only where nobody is waiting.
    public let stretchesForDevice: Bool

    /// Whether the call waits out an open breaker instead of failing at once.
    public let waitsForOpenBreaker: Bool

    /// The schedule's shape, for printing: the tables' own words.
    private let shape: ScheduleShape

    public var description: String {
        var parts = [
            "\(urgency)",
            "deadline \(deadline.compactDescription)",
            "schedule \(shape)",
            "attempt timeout \(attemptTimeout?.compactDescription ?? "none")",
            "breaker \(breaker?.description ?? "none")",
            "admission \(admission)",
        ]
        if let writers { parts.append("writers \(writers)") }
        if stretchesForDevice { parts.append("stretches for device") }
        if waitsForOpenBreaker { parts.append("waits for open breaker") }
        return parts.joined(separator: ", ")
    }
}

/// The breaker an operation's backend gets: what ``OperationPolicy`` prints.
///
/// Every other setting is ``CircuitBreaker/Configuration``'s default, but
/// for its counting (by classification, design/22) and that it has no
/// slow-call rule: an attempt timeout already counts as a failure, and a
/// window of slow `.long` transfers must not open the breaker for every
/// quick call to the same backend.
public struct BreakerPolicy: Sendable, Hashable, CustomStringConvertible {
    /// How long the breaker stays open, and how that grows.
    public let openDuration: CircuitBreaker.OpenDuration

    /// The fewest calls in the window before the breaker judges.
    public let minimumCalls: Int

    public var description: String {
        let open = openDuration
        var text = "open \(open.initial.compactDescription)"
        if open.factor > 1, open.maximum > open.initial {
            text += " ×\(open.factor.compactDescription) up to \(open.maximum.compactDescription)"
        }
        return text + ", \(Int((open.jitter * 100).rounded()))% jitter, at least \(minimumCalls) calls"
    }
}

/// The parameters of a derived schedule.
private struct ScheduleShape: Sendable, Hashable, CustomStringConvertible {
    let attempts: Int
    let base: Duration
    let cap: Duration

    var schedule: BoundedSchedule {
        Schedule.exponential(base: base).capped(at: cap).attempts(attempts)
    }

    var description: String {
        "\(attempts) · \(base.compactDescription) … \(cap.compactDescription)"
    }
}

extension OperationPolicy {
    /// The derivation: design/22's tables, each number written once, here.
    static func derived(
        kind: Backend.Kind, capacity: Int, safety: RepeatSafety, length: Backend.Operation.Length, urgency: Urgency
    ) -> OperationPolicy {
        let shape = Self.shape(kind: kind, urgency: urgency)
        let lenient = urgency <= .utility
        let breaker = Self.breaker(kind: kind)
        return OperationPolicy(
            urgency: urgency,
            deadline: Self.deadline(kind: kind, urgency: urgency).saturatingMultiplied(by: length == .long ? 3 : 1),
            schedule: shape.schedule,
            attemptTimeout: length == .brief ? Self.attemptTimeout(kind: kind, urgency: urgency) : nil,
            breaker: breaker,
            admission: Self.admission(capacity: capacity, urgency: urgency),
            writers: kind == .local && safety != .readOnly ? 1 : nil,
            stretchesForDevice: lenient,
            waitsForOpenBreaker: lenient && breaker != nil,
            shape: shape
        )
    }

    /// The total deadline, before a `.long` operation's tripling. Ten
    /// seconds is about as long as a person watches a spinner.
    private static func deadline(kind: Backend.Kind, urgency: Urgency) -> Duration {
        switch (kind, urgency) {
        case (.remote, .interactive): .seconds(10)
        case (.remote, .userInitiated): .seconds(30)
        case (.remote, .utility): .seconds(120)
        case (.remote, .background): .seconds(600)
        case (.system, .interactive): .seconds(5)
        case (.system, .userInitiated): .seconds(15)
        case (.system, .utility): .seconds(60)
        case (.system, .background): .seconds(300)
        case (.local, .interactive): .seconds(2)
        case (.local, .userInitiated): .seconds(10)
        case (.local, .utility): .seconds(60)
        case (.local, .background): .seconds(300)
        case (.compute, .interactive): .seconds(30)
        case (.compute, .userInitiated): .seconds(120)
        case (.compute, .utility): .seconds(600)
        case (.compute, .background): .seconds(1800)
        }
    }

    /// The schedule: a local store's transient failures clear in
    /// milliseconds or not at all; compute's retry costs as much as the
    /// attempt.
    private static func shape(kind: Backend.Kind, urgency: Urgency) -> ScheduleShape {
        switch (kind, urgency) {
        case (.remote, .interactive), (.system, .interactive):
            ScheduleShape(attempts: 2, base: .milliseconds(50), cap: .milliseconds(250))
        case (.remote, .userInitiated), (.system, .userInitiated):
            ScheduleShape(attempts: 3, base: .milliseconds(100), cap: .seconds(1))
        case (.remote, .utility), (.system, .utility):
            ScheduleShape(attempts: 4, base: .milliseconds(500), cap: .seconds(10))
        case (.remote, .background), (.system, .background):
            ScheduleShape(attempts: 6, base: .seconds(1), cap: .seconds(60))
        case (.local, .background):
            ScheduleShape(attempts: 5, base: .milliseconds(50), cap: .seconds(1))
        case (.local, _):
            ScheduleShape(attempts: 3, base: .milliseconds(10), cap: .milliseconds(100))
        case (.compute, .background):
            ScheduleShape(attempts: 3, base: .seconds(5), cap: .seconds(60))
        case (.compute, _):
            ScheduleShape(attempts: 2, base: .milliseconds(500), cap: .seconds(2))
        }
    }

    /// The attempt timeout of a `.brief` operation: two interactive
    /// attempts fit in the interactive deadline. `local` and `compute`
    /// have none: cancelling a write mid-transaction makes its outcome
    /// unknown for nothing, and a slow inference is not a stuck one.
    private static func attemptTimeout(kind: Backend.Kind, urgency: Urgency) -> Duration? {
        switch (kind, urgency) {
        case (.remote, .interactive): .seconds(4)
        case (.remote, .userInitiated): .seconds(10)
        case (.remote, .utility): .seconds(30)
        case (.remote, .background): .seconds(60)
        case (.system, .interactive): .seconds(2)
        case (.system, .userInitiated): .seconds(5)
        case (.system, .utility): .seconds(15)
        case (.system, .background): .seconds(30)
        case (.local, _), (.compute, _): nil
        }
    }

    /// The breaker: `CircuitBreaker`'s defaults with at least 20 calls in
    /// the window. launchd relaunches a crashed service in milliseconds, so
    /// a `system` breaker opens for 1 s at first, growing to 30 s. A full
    /// disk or a corrupt file is not an outage that heals while a breaker is
    /// open, so `local` and `compute` have none.
    private static func breaker(kind: Backend.Kind) -> BreakerPolicy? {
        switch kind {
        case .remote: BreakerPolicy(openDuration: .standard, minimumCalls: 20)
        case .system: BreakerPolicy(openDuration: .exponential(initial: .seconds(1), maximum: .seconds(30)), minimumCalls: 20)
        case .local, .compute: nil
        }
    }

    /// The slots calls at `urgency` or lower may hold together, rounded
    /// down, at least one: a person's tap always has a slot that row loads
    /// and syncs together cannot take, and background work never holds the
    /// last half.
    static func admission(capacity c: Int, urgency: Urgency) -> Int {
        let slots = switch urgency {
        case .interactive: c
        case .userInitiated: c - max(1, c / 4)
        case .utility: 3 * c / 4
        case .background: c / 2
        }
        return max(1, slots)
    }
}

extension Duration {
    /// The duration as the tables write it: `50 ms`, `10 s`, `2 min`.
    var compactDescription: String {
        let (seconds, attoseconds) = components
        if attoseconds == 0, seconds != 0, seconds % 60 == 0 { return "\(seconds / 60) min" }
        if attoseconds == 0 { return "\(seconds) s" }
        if attoseconds % 1_000_000_000_000_000 == 0 {
            return "\(seconds * 1000 + attoseconds / 1_000_000_000_000_000) ms"
        }
        return description
    }
}

extension Double {
    /// `2` rather than `2.0`, for whole numbers.
    fileprivate var compactDescription: String {
        rounded() == self && abs(self) < 1e15 ? "\(Int(self))" : "\(self)"
    }
}
