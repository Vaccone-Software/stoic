/// A type-erased clock measured in `Duration`.
///
/// Stoic stores deadlines and schedules against an `AnyClock` so that a clock
/// chosen at the edge of an app — the continuous clock in production, a test
/// clock in tests — reaches every primitive without generics leaking into
/// every signature.
///
/// An instant is a duration since the clock's origin, the moment the clock was
/// erased. Instants are only meaningful against the clock that produced them;
/// two erasures of the same underlying clock are different clocks, except for
/// ``continuous`` and ``suspending``, which are shared so that instants taken
/// from them anywhere in a process compare correctly.
public struct AnyClock: Clock, CustomStringConvertible {
    public typealias Duration = Swift.Duration

    /// A point in time on an ``AnyClock``: the duration since the clock's origin.
    public struct Instant: InstantProtocol, CustomStringConvertible {
        public typealias Duration = Swift.Duration

        /// The duration from the clock's origin to this instant.
        public var offset: Swift.Duration

        public init(offset: Swift.Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset.saturatingAdding(duration))
        }

        public func duration(to other: Instant) -> Swift.Duration {
            other.offset.saturatingSubtracting(offset)
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        public var description: String { "+\(offset)" }
    }

    // The erased clock. A class so that identity is cheap to compare: two
    // `AnyClock` values are the same clock exactly when they share a box.
    private final class Box: Sendable {
        let name: String
        let now: @Sendable () -> Swift.Duration
        let minimumResolution: Swift.Duration
        let sleep: @Sendable (Swift.Duration, Swift.Duration?) async throws -> Void
        let underlying: any Clock<Swift.Duration>
        let continuousOrigin: ContinuousClock.Instant?

        init<C: Clock<Swift.Duration>>(_ clock: C, name: String) {
            let origin = clock.now
            self.continuousOrigin = origin as? ContinuousClock.Instant
            self.name = name
            self.underlying = clock
            self.now = { origin.duration(to: clock.now) }
            self.minimumResolution = clock.minimumResolution
            self.sleep = { offset, tolerance in
                // Clamp to now and the horizon: underlying clocks trap on
                // instants they cannot represent, in either direction. "Wait
                // a very long time" should mean "wait for cancellation", and
                // "wait until long ago" should mean "do not wait", never a
                // crash.
                let now = origin.duration(to: clock.now)
                let target = min(max(offset, now), now.saturatingAdding(.horizon))
                try await clock.sleep(until: origin.advanced(by: target), tolerance: tolerance)
            }
        }
    }

    private let box: Box

    private init(box: Box) {
        self.box = box
    }

    /// Erases `clock`.
    ///
    /// Erasing an `AnyClock` returns it unchanged, and erasing
    /// `ContinuousClock` or `SuspendingClock` returns the shared
    /// ``continuous`` or ``suspending`` clock, so their instants stay
    /// comparable across the process.
    public init<C: Clock<Swift.Duration>>(_ clock: C, name: String? = nil) {
        if let erased = clock as? AnyClock {
            self = erased
        } else if name == nil, clock is ContinuousClock {
            self = .continuous
        } else if name == nil, clock is SuspendingClock {
            self = .suspending
        } else {
            self.init(box: Box(clock, name: name ?? String(describing: C.self)))
        }
    }

    /// The process-wide continuous clock: it keeps counting while the machine sleeps.
    ///
    /// The default for deadlines and retry delays: if a machine sleeps
    /// through a deadline, the deadline has passed.
    public static let continuous = AnyClock(box: Box(ContinuousClock(), name: "continuous"))

    /// The process-wide suspending clock: it stops while the machine sleeps.
    ///
    /// The default for liveness checks: a process that was asleep was not hung.
    public static let suspending = AnyClock(box: Box(SuspendingClock(), name: "suspending"))

    public var now: Instant { Instant(offset: box.now()) }

    public var minimumResolution: Swift.Duration { box.minimumResolution }

    public func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        try await box.sleep(deadline.offset, tolerance)
    }

    /// `instant` on the continuous clock itself, when this erases one, clamped
    /// as `sleep(until:tolerance:)` clamps it.
    ///
    /// For a caller that sleeps on the result directly, with no erasure's
    /// frames between its task and the sleep: see the deadline's timer.
    func continuousInstant(for instant: Instant) -> ContinuousClock.Instant? {
        guard let origin = box.continuousOrigin else { return nil }
        let now = box.now()
        let target = min(max(instant.offset, now), now.saturatingAdding(.horizon))
        return origin.advanced(by: target)
    }

    /// The clock this value erases.
    public var underlying: any Clock<Swift.Duration> { box.underlying }

    /// Whether `self` and `other` are the same clock, so their instants compare.
    public func isSameClock(as other: AnyClock) -> Bool {
        box === other.box
    }

    public var description: String { "AnyClock(\(box.name))" }
}
