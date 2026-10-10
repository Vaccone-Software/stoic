/// The instant by which work must finish.
///
/// A deadline is absolute: passed through three layers of calls, it still
/// means the same instant, where a timeout passed the same way would grow by
/// each layer's own overhead. The deadline in force for the current task is
/// ``current``; ``withDeadline(_:tolerance:operation:)`` narrows it for an
/// operation and everything that operation calls. It is never widened: an
/// inner deadline later than the outer one has no effect.
public struct Deadline: Sendable, CustomStringConvertible {
    /// The instant, on ``clock``.
    public let instant: AnyClock.Instant

    /// The clock the instant belongs to.
    public let clock: AnyClock

    public init(_ instant: AnyClock.Instant, clock: AnyClock) {
        self.instant = instant
        self.clock = clock
    }

    /// The deadline `duration` from now, on `clock` (the ambient clock by default).
    public static func after(_ duration: Duration, clock: AnyClock? = nil) -> Deadline {
        let clock = clock ?? Ambient.current.clock
        return Deadline(clock.now.advanced(by: duration), clock: clock)
    }

    @TaskLocal static var stored: Deadline?

    /// The deadline in force for the current task, if any.
    public static var current: Deadline? { stored }

    /// The time left before the deadline; zero once it has passed.
    public var remaining: Duration {
        max(.zero, clock.now.duration(to: instant))
    }

    /// Whether the deadline has passed.
    public var hasPassed: Bool {
        clock.now >= instant
    }

    /// The earlier of two deadlines.
    ///
    /// Deadlines on the same clock compare by instant. Deadlines on different
    /// clocks compare by the time each has left at the moment of comparison,
    /// which is exact when both clocks advance together and an approximation
    /// otherwise; mixing clocks is best avoided.
    public func earlier(_ other: Deadline) -> Deadline {
        if clock.isSameClock(as: other.clock) {
            return other.instant < instant ? other : self
        }
        return other.remaining < remaining ? other : self
    }

    /// `self`, narrowed by the deadline already in force.
    var narrowedByCurrent: Deadline {
        Deadline.current.map(earlier) ?? self
    }

    public var description: String {
        "Deadline(\(instant) on \(clock), \(remaining) remaining)"
    }
}
