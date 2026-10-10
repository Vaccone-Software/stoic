public import Stoic
internal import Synchronization

/// A clock on which every sleep returns at once, having moved time forward.
///
/// For tests that care what was waited for, not about racing anything
/// against the wait: a retry's backoff sequence, a schedule's delays. Each
/// sleep advances `now` to its deadline and is recorded, so a test can assert
/// the exact delays a primitive chose.
public final class ImmediateClock: Clock, Sendable {
    public typealias Duration = Swift.Duration
    public typealias Instant = TestClock.Instant

    private struct State {
        var now: Swift.Duration = .zero
        var sleeps: [Swift.Duration] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// This clock, erased, for ``Ambient`` or any `clock:` parameter.
    public var erased: AnyClock {
        AnyClock(self, name: "immediate")
    }

    public var now: Instant {
        state.withLock { Instant(offset: $0.now) }
    }

    public var minimumResolution: Swift.Duration { .zero }

    /// Every sleep so far, as the duration from `now` to its deadline.
    public var sleeps: [Swift.Duration] {
        state.withLock { $0.sleeps }
    }

    public func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        try Task.checkCancellation()
        state.withLock { state in
            state.sleeps.append(max(.zero, deadline.offset - state.now))
            state.now = max(state.now, deadline.offset)
        }
        await Task.yield()
        try Task.checkCancellation()
    }
}
