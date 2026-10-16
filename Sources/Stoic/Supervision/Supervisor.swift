internal import Synchronization

/// Keeps long-lived work running: restarts children that fail, and gives up
/// — loudly — when they fail too often.
///
/// Erlang/OTP's supervisor, for the work an app keeps alive in the
/// background: a sync engine, an event tap, a socket listener, a model
/// server. Children are factories, so a restart gets fresh state.
///
///     let supervisor = Supervisor(label: "app", strategy: .oneForOne) {
///         Child("sync", restart: .permanent) { _ in try await SyncEngine(store: store).run() }
///         Child("tap", restart: .permanent, heartbeat: .init(interval: .seconds(5))) { heartbeat in
///             try await EventTap(onTick: heartbeat.beat).run()
///         }
///     }
///     try await supervisor.run()
///
/// **Restart policies.** `.permanent` children are always restarted,
/// `.transient` ones only when they throw, `.temporary` ones never.
///
/// **Strategies.** `.oneForOne` restarts only the child that stopped.
/// `.oneForAll` stops every child (newest first) and restarts them all, for
/// children that depend on each other. `.restForOne` restarts the stopped
/// child and every child started after it — the ones that may depend on it.
///
/// **Intensity.** More than `intensity.maxRestarts` restarts within
/// `intensity.window` means restarting is not helping: the supervisor stops
/// every child and throws ``SupervisorEscalation``, so whatever runs it — a
/// parent supervisor, a service graph, the process's own lifecycle — can
/// take the next, bigger step. In-process, the biggest step is ending the
/// process: Swift cannot recover a trapped task, so a crash is handled by
/// what restarts processes (launchd, the OS relaunching an app).
///
/// **Backoff.** Each child waits on `backoff` before restarting; a child that
/// ran for `resetAfter` without stopping starts its backoff over.
///
/// **Heartbeats.** A child given a ``HeartbeatPolicy`` must call
/// `heartbeat.beat()` at least every `interval`. After `misses` consecutive
/// silent intervals the child is treated as hung: cancelled and restarted.
/// Heartbeats are measured on the *liveness* clock, which stops while the
/// machine sleeps — a process that was asleep was not hung — and are not
/// checked during a child's `grace` period after it starts. A check that
/// runs more than an interval late (the process was suspended while that
/// clock ran on) is a gap, not a miss: counting starts again from then.
///
/// **Stopping.** Children stop newest first. Each is cancelled
/// (``CancellationCause/supervisorStopped``) and given `shutdownTimeout`;
/// one that does not stop by then is abandoned and reported.
public final class Supervisor: Sendable {
    /// Which children restart when one stops.
    public enum Strategy: Sendable, Hashable {
        case oneForOne
        case oneForAll
        case restForOne
    }

    /// How many restarts within a window mean "this is not working".
    public struct Intensity: Sendable, Hashable {
        public let maxRestarts: Int
        public let window: Duration

        public init(maxRestarts: Int, within window: Duration) {
            precondition(maxRestarts >= 0, "maxRestarts must not be negative")
            self.maxRestarts = maxRestarts
            self.window = window
        }

        /// Five restarts a minute.
        public static let standard = Intensity(maxRestarts: 5, within: .seconds(60))
    }

    public let label: String
    public let strategy: Strategy
    public let intensity: Intensity
    public let backoff: Schedule
    public let resetAfter: Duration
    let children: [Child]

    private struct Subscribers {
        var continuations: [UInt64: AsyncStream<SupervisorEvent>.Continuation] = [:]
        var next: UInt64 = 0
        var finished = false
    }

    private let subscribers = Mutex(Subscribers())
    private let running = Mutex(false)

    public init(
        label: String,
        strategy: Strategy = .oneForOne,
        intensity: Intensity = .standard,
        backoff: Schedule = .exponential(base: .milliseconds(500)).capped(at: .seconds(30)),
        resetAfter: Duration = .seconds(30),
        @ChildrenBuilder children: () -> [Child]
    ) {
        self.label = label
        self.strategy = strategy
        self.intensity = intensity
        self.backoff = backoff
        self.resetAfter = resetAfter
        self.children = children()
        precondition(Set(self.children.map { $0.label }).count == self.children.count, "Supervisor \(label): child labels must be unique")
    }

    /// What the supervisor does, as it happens: starts, exits, restarts,
    /// hangs, escalation.
    ///
    /// Each call returns a stream of its own, so a UI and a parent each see
    /// every event; a stream sees what happens after it was made (make it
    /// before ``run()`` to see everything) and buffers the newest 256. Every
    /// stream finishes when `run()` ends; one made after that finishes at once.
    public func events() -> AsyncStream<SupervisorEvent> {
        let (stream, continuation) = AsyncStream<SupervisorEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = subscribers.withLock { subscribers -> UInt64? in
            if subscribers.finished { return nil }
            defer { subscribers.next += 1 }
            subscribers.continuations[subscribers.next] = continuation
            return subscribers.next
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        // A subscriber that stops listening is forgotten.
        continuation.onTermination = { [weak self] _ in
            self?.subscribers.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// Delivers `event` to every ``events()`` stream.
    func publish(_ event: SupervisorEvent) {
        let listeners = subscribers.withLock { $0.continuations.valuesInKeyOrder }
        for listener in listeners { listener.yield(event) }
    }

    /// Finishes every ``events()`` stream, and every one made later.
    private func finishEvents() {
        let listeners = subscribers.withLock { subscribers in
            subscribers.finished = true
            defer { subscribers.continuations.removeAll() }
            return subscribers.continuations.valuesInKeyOrder
        }
        for listener in listeners { listener.finish() }
    }

    /// Runs the children until they are all done, the supervisor escalates,
    /// or the calling task is cancelled. A supervisor runs once.
    ///
    /// - Throws: ``SupervisorEscalation`` when restarts exceed the intensity;
    ///   `CancellationError` when cancelled (after every child has stopped).
    public func run() async throws {
        let alreadyRan = running.withLock { running -> Bool in
            defer { running = true }
            return running
        }
        precondition(!alreadyRan, "Supervisor \(label) runs once; create a new one to run again")
        // The event streams end with the run, so `for await` over them ends too.
        defer { finishEvents() }
        let run = SupervisorRun(supervisor: self, ambient: Ambient.current)
        try await run.execute()
    }
}

/// Something a supervisor did.
public enum SupervisorEvent: Sendable, Hashable {
    case started(child: String)
    case exited(child: String, failed: Bool)
    case restarting(child: String, after: Duration)
    case hung(child: String)
    case escalated(child: String)
    case stopped
}

/// What a supervisor throws when restarting stopped helping.
public struct SupervisorEscalation: Error, CustomStringConvertible {
    public let supervisor: String
    /// The child whose stop exceeded the intensity.
    public let child: String
    /// The error that child last threw, if it threw.
    public let lastError: (any Error)?

    public var description: String {
        "supervisor \(supervisor) gave up after child \(child) stopped too often" + (lastError.map { ": \($0)" } ?? "")
    }
}

/// When a child is restarted.
public enum RestartPolicy: Sendable, Hashable {
    /// Always: it is meant to run for the supervisor's lifetime.
    case permanent
    /// Only when it throws: returning normally means it finished its job.
    case transient
    /// Never.
    case temporary
}

/// How often a child must prove it is alive.
public struct HeartbeatPolicy: Sendable, Hashable {
    public let interval: Duration
    public let misses: Int
    public let grace: Duration

    /// - Parameters:
    ///   - interval: The longest the child may go without beating.
    ///   - misses: Consecutive silent intervals that mean "hung". More than
    ///     one, so a single slow moment is not a hang.
    ///   - grace: Time after start before heartbeats are checked, for slow
    ///     launches.
    public init(interval: Duration, misses: Int = 3, grace: Duration = .seconds(30)) {
        precondition(misses >= 1, "misses must be at least one")
        self.interval = interval
        self.misses = misses
        self.grace = grace
    }
}

/// Lets a child prove it is alive.
public final class Heartbeat: Sendable {
    private let beats = Mutex<UInt64>(0)

    init() {}

    /// Records that the child is alive and making progress.
    public func beat() {
        beats.withLock { $0 &+= 1 }
    }

    var count: UInt64 {
        beats.withLock { $0 }
    }
}

/// One supervised piece of work.
public struct Child: Sendable {
    public let label: String
    public let restart: RestartPolicy
    public let heartbeat: HeartbeatPolicy?
    public let shutdownTimeout: Duration
    let run: @Sendable (Heartbeat) async throws -> Void

    public init(
        _ label: String,
        restart: RestartPolicy = .permanent,
        heartbeat: HeartbeatPolicy? = nil,
        shutdownTimeout: Duration = .seconds(5),
        run: @escaping @Sendable (Heartbeat) async throws -> Void
    ) {
        self.label = label
        self.restart = restart
        self.heartbeat = heartbeat
        self.shutdownTimeout = shutdownTimeout
        self.run = run
    }
}

extension CancellationCause {
    /// The child stopped beating and is being restarted as hung.
    public static let childHung = CancellationCause(rawValue: "child_hung")
}

/// Collects a supervisor's children.
@resultBuilder
public enum ChildrenBuilder {
    public static func buildExpression(_ child: Child) -> [Child] { [child] }
    public static func buildExpression(_ children: [Child]) -> [Child] { children }
    public static func buildBlock(_ parts: [Child]...) -> [Child] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [Child]?) -> [Child] { part ?? [] }
    public static func buildEither(first: [Child]) -> [Child] { first }
    public static func buildEither(second: [Child]) -> [Child] { second }
    public static func buildArray(_ parts: [[Child]]) -> [Child] { parts.flatMap { $0 } }
}
