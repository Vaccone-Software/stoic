internal import Synchronization

/// Notices when work goes quiet: no sign of life for a stretch, measured on
/// a clock that stops while the machine sleeps.
///
/// Work that should show signs of progress (a session streaming a reply, a
/// build printing, a download moving) calls ``poke()`` at each one. A
/// watcher waits in ``untilQuiet()``, which returns once `after` has passed
/// with no poke, or iterates ``quietSpells()`` to hear of each quiet spell
/// once. A poke is a write under a lock: cheap enough for every line.
///
/// Measured by a wall clock, a laptop that slept for an hour wakes to find
/// all its work an hour quiet, and calls it stuck; here the stretch is
/// measured on ``Ambient/livenessClock`` (the suspending clock, which does
/// not advance during sleep), as a ``Supervisor``'s heartbeats are, so
/// sleeping is never silence. Under `withTestAmbient` it is the test clock.
///
/// A supervisor's heartbeat restarts the child that stops beating; this
/// decides nothing. What a quiet spell means (stuck, waiting on something
/// slow, finished without saying) is the caller's to judge.
public final class Inactivity: Sendable, CustomStringConvertible {
    /// How long without a poke counts as quiet.
    public let after: Duration
    public let label: String
    private let clock: AnyClock
    private let state: Mutex<State>

    private struct State {
        var lastPoke: AnyClock.Instant
        var pokes: UInt64 = 0
        var reported: UInt64?
        var waiters: [(id: UInt64, waiter: CheckedContinuation<Void, Never>)] = []
        var nextWaiter: UInt64 = 0
    }

    /// - Parameters:
    ///   - after: How long without a poke counts as quiet. Positive.
    ///   - label: Names it in events.
    ///   - clock: The clock it measures on; ``Ambient/livenessClock`` when
    ///     nil, read once, here.
    public init(after: Duration, label: String, clock: AnyClock? = nil) {
        precondition(after > .zero, "Inactivity: `after` must be positive")
        self.after = after
        self.label = label
        let clock = clock ?? Ambient.current.livenessClock
        self.clock = clock
        state = Mutex(State(lastPoke: clock.now))
    }

    /// A sign of life: the quiet stretch starts again from now.
    public func poke() {
        let now = clock.now
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.lastPoke = now
            state.pokes &+= 1
            defer { state.waiters = [] }
            return state.waiters.map(\.waiter)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// How long since the last poke (or since it was made).
    public var quietFor: Duration {
        let now = clock.now
        return state.withLock { $0.lastPoke.duration(to: now) }
    }

    /// Whether `after` has passed since the last poke.
    public var isQuiet: Bool { quietFor >= after }

    /// Returns once `after` has passed since the last poke: at once if it
    /// already has. A poke while it waits moves the end of the wait, and
    /// costs the poker nothing: the watcher, on waking, sees the newer poke
    /// and sleeps again for what is left.
    ///
    /// - Throws: `CancellationError` when the task is cancelled.
    public func untilQuiet() async throws(CancellationError) {
        while true {
            let lastPoke = state.withLock { $0.lastPoke }
            let quietAt = lastPoke.advanced(by: after)
            if clock.now >= quietAt { return }
            do {
                try await clock.sleep(until: quietAt, tolerance: nil)
            } catch {
                throw CancellationError()
            }
        }
    }

    /// Returns at the first poke made after it was called.
    ///
    /// - Throws: `CancellationError` when the task is cancelled.
    public func nextPoke() async throws(CancellationError) {
        try await poke(after: state.withLock { $0.pokes })
    }

    /// Returns once a poke after the `seen`-th has been made: at once if one
    /// already has. The count is compared and the waiter registered under one
    /// lock, so a poke between a caller's reading of the count and its wait
    /// is never lost.
    private func poke(after seen: UInt64) async throws(CancellationError) {
        let id = state.withLock { state -> UInt64 in
            defer { state.nextWaiter &+= 1 }
            return state.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let now = state.withLock { state -> Bool in
                    if Task.isCancelled || state.pokes != seen { return true }
                    state.waiters.append((id, waiter))
                    return false
                }
                if now { waiter.resume() }
            }
        } onCancel: {
            state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index).waiter
            }?.resume()
        }
        if Task.isCancelled { throw CancellationError() }
    }

    /// Each quiet spell, once: an element when the work has been quiet for
    /// `after`, then none until it has been poked and gone quiet again. The
    /// element is how long it had been quiet when the spell was noticed.
    /// Ends when the iterating task is cancelled.
    public func quietSpells() -> QuietSpells { QuietSpells(inactivity: self) }

    /// The quiet spells of an ``Inactivity``.
    public struct QuietSpells: AsyncSequence, Sendable {
        public typealias Element = Duration
        public typealias Failure = Never

        let inactivity: Inactivity

        public struct AsyncIterator: AsyncIteratorProtocol {
            let inactivity: Inactivity

            public mutating func next() async -> Duration? {
                await inactivity.nextSpell()
            }

            public mutating func next(isolation actor: isolated (any Actor)?) async -> Duration? {
                await inactivity.nextSpell()
            }
        }

        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(inactivity: inactivity) }
    }

    /// The next spell not yet reported, or nil when cancelled.
    private func nextSpell() async -> Duration? {
        do {
            while true {
                // A spell already reported lasts until the next poke.
                let (reportedThisSpell, pokes) = state.withLock { ($0.reported == $0.pokes, $0.pokes) }
                if reportedThisSpell { try await poke(after: pokes) }
                try await untilQuiet()
                let (fresh, quiet) = state.withLock { state -> (Bool, Duration) in
                    let quiet = state.lastPoke.duration(to: clock.now)
                    guard quiet >= after, state.reported != state.pokes else { return (false, quiet) }
                    state.reported = state.pokes
                    return (true, quiet)
                }
                if fresh {
                    Ambient.record(Event("inactivity.quiet", level: .info, label: label,
                                         fields: [.init("quiet", .duration(quiet))]))
                    return quiet
                }
            }
        } catch {
            return nil
        }
    }

    public var description: String { "Inactivity(\(label), after \(after))" }
}
