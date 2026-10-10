internal import Synchronization

/// Stops calling a dependency that is failing, and tests whether it has
/// recovered a little at a time.
///
/// A breaker is *closed* while calls succeed, and records each one in a
/// sliding window. When the window holds enough calls and too many of them
/// failed, or were slow, the breaker *opens*: calls are rejected at once with
/// ``Rejection/Reason/circuitOpen`` and a `retryAfter` saying when it will
/// look again, sparing both the dependency, which is struggling, and the
/// caller, who would otherwise wait out a timeout to learn what the breaker
/// already knows. After the open duration the breaker is *half-open*: a
/// limited number of calls are let through as probes, and the rest are still
/// rejected. If the probes succeed the breaker closes; if one fails it opens
/// again, for longer.
///
/// Admission is a synchronous check under a lock: no actor hop, no
/// background task. Nothing watches the clock; the open period is an instant,
/// and the move to half-open happens when the next call (or a read of
/// ``state``) finds that instant has passed. A breaker owns no task and needs
/// no teardown.
///
/// What counts is explained on ``Configuration/recordWhen``; in short,
/// failures count, a cancelled caller never does, and neither does a bug in
/// our own code (a ``Defect``) or a refusal from another policy.
///
///     let breaker = CircuitBreaker(label: "payments")
///     do {
///         let receipt = try await breaker.execute { try await gateway.charge(order) }
///     } catch {
///         if error.rejection?.reason == .circuitOpen { showOfflineBanner(until: error.rejection?.retryAfter) }
///     }
public final class CircuitBreaker: Policy, CustomStringConvertible {
    /// Where a breaker is in its cycle.
    public enum State: Sendable, Hashable, CustomStringConvertible {
        /// Calls run and are recorded.
        case closed
        /// Calls are rejected.
        case open
        /// A limited number of probe calls run; the rest are rejected.
        case halfOpen

        public var description: String {
            switch self {
            case .closed: "closed"
            case .open: "open"
            case .halfOpen: "half-open"
            }
        }
    }

    /// What the breaker remembers when it judges.
    public enum Window: Sendable, Hashable {
        /// The last `N` calls, exactly. Independent of traffic rate: the
        /// right choice for a steady, busy dependency.
        case calls(Int)
        /// The calls of the last span, in ten buckets (so the edge is coarse
        /// by a tenth). Forgets old calls on its own: the right choice, and
        /// the default, for an app whose traffic is bursty and idle between.
        case time(Duration)
    }

    /// How long the breaker stays open, and how that grows.
    public struct OpenDuration: Sendable, Hashable {
        /// The first open period.
        public var initial: Duration
        /// The multiplier for each repeated trip; 1 keeps the duration fixed.
        public var factor: Double
        /// The longest open period, jitter aside.
        public var maximum: Duration
        /// The fraction of the period that may be randomly *removed*, in
        /// 0...1. Jitter only shortens, so the maximum holds; its purpose is
        /// that many clients opened by the same outage do not all probe at
        /// the same instant.
        public var jitter: Double
        /// How long the breaker must stay closed before the next trip starts
        /// again from `initial`. Closing alone does not reset the growth,
        /// which is what makes a flapping dependency earn longer rests.
        public var resetAfter: Duration

        public init(initial: Duration, factor: Double, maximum: Duration, jitter: Double, resetAfter: Duration? = nil) {
            self.initial = initial
            self.factor = factor
            self.maximum = maximum
            self.jitter = jitter
            self.resetAfter = resetAfter ?? maximum
        }

        /// Open for the same time on every trip.
        public static func fixed(_ duration: Duration, jitter: Double = 0.2) -> OpenDuration {
            OpenDuration(initial: duration, factor: 1, maximum: duration, jitter: jitter, resetAfter: duration)
        }

        /// Open for `initial × factor^k` on the k-th consecutive trip, up to `maximum`.
        public static func exponential(
            initial: Duration = .seconds(30), factor: Double = 2, maximum: Duration = .seconds(300),
            jitter: Double = 0.2, resetAfter: Duration? = nil
        ) -> OpenDuration {
            OpenDuration(initial: initial, factor: factor, maximum: maximum, jitter: jitter, resetAfter: resetAfter)
        }

        /// The default: 30 s, doubling per repeated trip, up to 5 minutes, 20% jitter.
        public static let standard = OpenDuration.exponential()

        /// The period for trip number `trip` (0 for the first), before jitter.
        func base(forTrip trip: Int) -> Duration {
            var duration = initial
            var remaining = trip
            while remaining > 0, duration < maximum, factor > 1 {
                duration = duration.saturatingMultiplied(by: factor)
                remaining -= 1
            }
            return min(duration, maximum)
        }
    }

    /// Every setting of a breaker. The defaults are meant to be safe for an
    /// app calling a network service: slow to trip, because tripping by
    /// mistake costs an outage of its own, and slow to forgive.
    public struct Configuration: Sendable {
        /// What is remembered. Default: the last 60 seconds.
        public var window: Window
        /// The fewest calls in the window before the breaker will judge.
        /// Default 10: a rate over two or three calls is noise.
        public var minimumCalls: Int
        /// Opens when this fraction of the window's calls failed, in (0, 1]
        /// (compared with `≥`). Default 0.5.
        public var failureRateThreshold: Double
        /// A call taking longer than this is *slow*. Default 10 s.
        public var slowCallDuration: Duration
        /// Opens when this fraction of the window's calls were slow, in
        /// (0, 1] (compared with `≥`). Default 1: every call in the window
        /// was slow. A dependency that is slow but answering is usually
        /// better left alone than cut off.
        public var slowCallRateThreshold: Double
        /// How long to stay open. Default: 30 s doubling to 5 minutes.
        public var openDuration: OpenDuration
        /// The number of probe calls half-open allows. All must succeed to
        /// close; the first failure re-opens. Default 1: the gentlest test.
        public var halfOpenProbes: Int
        /// A probe running this long is given up on: the breaker re-opens
        /// and the late probe is ignored. Default 60 s. Without it, one hung
        /// probe would hold half-open shut for good.
        public var halfOpenTimeout: Duration
        /// Whether a call that ended in this error is recorded as a failure.
        ///
        /// Called with the operation's own error (inside a pipeline the
        /// ``PolicyError`` layers are removed first), or with the
        /// ``Rejection`` an inner policy raised. `true` records a failure;
        /// `false` records a success — a `404` is the dependency answering —
        /// except for a rejection, which is then not recorded at all.
        ///
        /// Not consulted for a cancelled caller or a ``Defect``: those are
        /// never recorded. The default is ``CircuitBreaker/countsByDefault(_:)``.
        public var recordWhen: @Sendable (any Error) -> Bool

        public init(
            window: Window = .time(.seconds(60)),
            minimumCalls: Int = 10,
            failureRateThreshold: Double = 0.5,
            slowCallDuration: Duration = .seconds(10),
            slowCallRateThreshold: Double = 1,
            openDuration: OpenDuration = .standard,
            halfOpenProbes: Int = 1,
            halfOpenTimeout: Duration = .seconds(60),
            recordWhen: @escaping @Sendable (any Error) -> Bool = CircuitBreaker.countsByDefault
        ) {
            self.window = window
            self.minimumCalls = minimumCalls
            self.failureRateThreshold = failureRateThreshold
            self.slowCallDuration = slowCallDuration
            self.slowCallRateThreshold = slowCallRateThreshold
            self.openDuration = openDuration
            self.halfOpenProbes = halfOpenProbes
            self.halfOpenTimeout = halfOpenTimeout
            self.recordWhen = recordWhen
        }
    }

    /// A reading of a breaker, for dashboards and tests.
    public struct Snapshot: Sendable {
        public var state: State
        /// Calls in the window (closed state only; empty otherwise).
        public var calls: Int
        public var failures: Int
        public var slowCalls: Int
        public var failureRate: Double
        public var slowCallRate: Double
        /// Consecutive trips counted toward the next open duration.
        public var trips: Int
        /// While open, the time until half-open; `nil` if forced open or not open.
        public var retryAfter: Duration?
    }

    /// The default for ``Configuration/recordWhen``: everything counts as a
    /// failure except a ``Rejection``.
    ///
    /// A bulkhead that is full, a limiter that refuses, a budget that has run
    /// dry — none of these says anything about the dependency's health, so
    /// they must not push the breaker toward opening. (Caller cancellation
    /// and defects are excluded before any classifier runs.) A
    /// `CancellationError` thrown while the caller is *not* cancelled means
    /// something inside — an attempt timeout — cut the call short, which is a
    /// failure of the dependency to answer in time.
    public static func countsByDefault(_ error: any Error) -> Bool {
        !(error is Rejection)
    }

    /// Names the breaker in rejections and events.
    public let label: String

    private let configuration: Configuration
    private let clock: AnyClock
    private let failurePPM: Int
    private let slowPPM: Int
    private let fileID: String
    private let line: UInt

    // MARK: State

    private enum Phase: Sendable {
        case closed
        case open(until: AnyClock.Instant?)   // nil: forced open
        case halfOpen

        var state: State {
            switch self {
            case .closed: .closed
            case .open: .open
            case .halfOpen: .halfOpen
            }
        }
    }

    private struct Core: Sendable {
        var phase: Phase = .closed
        // Bumped on every transition. A call carries the generation it was
        // admitted under, so one that finishes after the breaker has moved
        // on is recognised as stale instead of being counted in a window it
        // never belonged to.
        var generation: UInt64 = 0
        var window: OutcomeWindow
        var trips = 0
        var closedAt: AnyClock.Instant
        // The half-open episode.
        var successes = 0
        var inFlight: [UInt64: AnyClock.Instant] = [:]
        var nextProbe: UInt64 = 0
        // States entered but not yet published to stateChanges.
        var outbox: [State] = []
    }

    private let core: Mutex<Core>

    // Subscribers to stateChanges, and the lock that keeps publication in
    // transition order. Lock order: publishing, then core or subscribers,
    // never the reverse; no lock is held while yielding to a stream
    // except `publishing`, which nothing a stream can call takes.
    private struct Subscribers: Sendable {
        var next: UInt64 = 0
        var continuations: [UInt64: AsyncStream<State>.Continuation] = [:]
    }
    private let subscribers = Mutex(Subscribers())
    private let publishing = Mutex(())

    /// A breaker.
    ///
    /// - Parameters:
    ///   - label: Names the breaker in rejections and events.
    ///   - configuration: Its settings; the defaults are described there.
    ///   - clock: The clock to measure time on; by default the ambient clock
    ///     when the breaker is created. A breaker compares instants across
    ///     calls, so it measures time on one clock for its whole life.
    public init(
        label: String,
        _ configuration: Configuration = Configuration(),
        clock: AnyClock? = nil,
        fileID: String = #fileID,
        line: UInt = #line
    ) {
        precondition(configuration.minimumCalls >= 1, "a breaker must see at least one call before judging")
        precondition(configuration.halfOpenProbes >= 1, "half-open needs at least one probe")
        precondition(configuration.slowCallDuration > .zero, "the slow-call duration must be positive")
        precondition(configuration.halfOpenTimeout > .zero, "the half-open timeout must be positive")
        let open = configuration.openDuration
        precondition(open.initial > .zero && open.maximum >= open.initial, "open durations must be positive and ordered")
        precondition(open.factor >= 1 && open.factor.isFinite, "the open-duration factor must be at least 1")
        precondition((0...1).contains(open.jitter), "jitter is a fraction between 0 and 1")
        precondition(open.resetAfter >= .zero, "resetAfter cannot be negative")
        let failurePPM = Self.partsPerMillion(configuration.failureRateThreshold, "failureRateThreshold")
        let slowPPM = Self.partsPerMillion(configuration.slowCallRateThreshold, "slowCallRateThreshold")
        let window: OutcomeWindow
        switch configuration.window {
        case .calls(let count):
            precondition(count >= 1, "a count window needs at least one call")
            precondition(configuration.minimumCalls <= count, "minimumCalls cannot exceed the window, or the breaker could never judge")
            window = OutcomeWindow(lastCalls: count)
        case .time(let span):
            window = OutcomeWindow(lastSpan: span)
        }
        let clock = clock ?? Ambient.current.clock
        self.label = label
        self.configuration = configuration
        self.clock = clock
        self.failurePPM = failurePPM
        self.slowPPM = slowPPM
        self.fileID = fileID
        self.line = line
        self.core = Mutex(Core(window: window, closedAt: clock.now))
    }

    private static func partsPerMillion(_ rate: Double, _ name: String) -> Int {
        precondition(rate > 0 && rate <= 1, "\(name) must be in (0, 1]")
        let ppm = Int((rate * 1_000_000).rounded())
        precondition(ppm >= 1, "\(name) is too small to compare exactly")
        return ppm
    }

    // MARK: Reading

    /// The breaker's state now. Reading it performs the move from open to
    /// half-open if the open period has ended.
    public var state: State {
        let random = Ambient.current.random
        let (state, changes) = core.withLock { core -> (State, [Change]) in
            let changes = refresh(&core, now: clock.now, random: random)
            return (core.phase.state, changes)
        }
        finish(changes)
        return state
    }

    /// A reading of the breaker: its state, its window and its trip count.
    public var snapshot: Snapshot {
        let random = Ambient.current.random
        let (snapshot, changes) = core.withLock { core -> (Snapshot, [Change]) in
            let now = clock.now
            let changes = refresh(&core, now: now, random: random)
            let totals = core.window.totals(at: now)
            var retryAfter: Duration?
            if case .open(let until?) = core.phase { retryAfter = max(.zero, now.duration(to: until)) }
            return (
                Snapshot(
                    state: core.phase.state, calls: totals.calls, failures: totals.failures,
                    slowCalls: totals.slowCalls, failureRate: totals.failureRate,
                    slowCallRate: totals.slowCallRate, trips: core.trips, retryAfter: retryAfter
                ),
                changes
            )
        }
        finish(changes)
        return snapshot
    }

    /// Every state the breaker enters, in order.
    ///
    /// Each access is its own stream. It does not replay the current state
    /// (subscribe, then read ``state``), and it keeps the newest 16 states
    /// for a consumer that falls behind; the breaker never waits for a
    /// consumer. The move out of open is lazy, so half-open is reported when
    /// a call or a read of ``state`` first finds the open period over.
    public var stateChanges: AsyncStream<State> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let id = subscribers.withLock { subscribers -> UInt64 in
                subscribers.next += 1
                subscribers.continuations[subscribers.next] = continuation
                return subscribers.next
            }
            continuation.onTermination = { [weak self] _ in
                self?.subscribers.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        }
    }

    // MARK: Executing

    /// Runs `operation` if the breaker admits it.
    ///
    /// - Throws: `.failed` with the operation's own error; or `.rejected`:
    ///   `.circuitOpen` (with `retryAfter` while open, none while half-open
    ///   and every probe is out), `.cancelled` if the task was already
    ///   cancelled, or `.deadlineExceeded` if ``Deadline/current`` had
    ///   already passed. A refusal to start never uses up a probe.
    public nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        if let refusal = Rejection.refusedBeforeStart(label: label) {
            Ambient.record(Event("breaker.rejected", level: .debug, label: label, fields: [
                .init("reason", .string(refusal.reason.rawValue), privacy: .public),
            ]))
            throw .rejected(refusal)
        }
        let random = Ambient.current.random
        let start = clock.now
        let (admission, changes) = core.withLock { core -> (Admission, [Change]) in
            let changes = refresh(&core, now: start, random: random)
            return (admit(&core, now: start), changes)
        }
        finish(changes)

        let ticket: Ticket
        switch admission {
        case .run(let admitted):
            ticket = admitted
        case .reject(let rejection, let state):
            var fields: [Event.Field] = [.init("state", .string(state.description), privacy: .public)]
            if let retryAfter = rejection.retryAfter { fields.append(.init("retry_after", .duration(retryAfter))) }
            Ambient.record(Event("breaker.rejected", level: .debug, label: label, fields: fields))
            throw .rejected(rejection)
        }

        let result: Result<R, Failure>
        do throws(Failure) {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }

        let end = clock.now
        let verdict = judge(result, duration: start.duration(to: end), callerCancelled: Task.isCancelled)
        let completion = core.withLock { core -> [Change] in
            complete(&core, ticket: ticket, verdict: verdict, now: end, random: random)
        }
        finish(completion)

        switch result {
        case .success(let value): return value
        case .failure(let failure): throw .failed(failure)
        }
    }

    // MARK: Manual control

    /// Opens the breaker with no end: it rejects every call and does not
    /// move to half-open until ``forceClosed()`` or ``reset()``.
    public func forceOpen() {
        let changes = core.withLock { core -> [Change] in
            let now = clock.now
            let totals = core.window.totals(at: now)
            if case .open(until: nil) = core.phase { return [] }
            return open(&core, now: now, until: nil, trigger: "forced", totals: totals, openFor: nil)
        }
        finish(changes)
    }

    /// Closes the breaker now, with an empty window. Normal judging resumes;
    /// this is not a latch. Calls in flight finish as stale.
    public func forceClosed() {
        let changes = core.withLock { core in
            closeNow(&core, now: clock.now, reason: "forced")
        }
        finish(changes)
    }

    /// ``forceClosed()``, and forget the trip count, so the next trip starts
    /// again from the initial open duration.
    public func reset() {
        let changes = core.withLock { core -> [Change] in
            core.trips = 0
            var changes = closeNow(&core, now: clock.now, reason: "reset")
            changes.append(Change(name: "breaker.reset", level: .notice, fields: []))
            return changes
        }
        finish(changes)
    }

    // MARK: Admission and completion (under the lock)

    private struct Ticket: Sendable {
        let generation: UInt64
        let probe: UInt64?
    }

    private enum Admission: Sendable {
        case run(Ticket)
        case reject(Rejection, State)
    }

    private enum Verdict: Sendable {
        case ignored(String)
        case recorded(failed: Bool, slow: Bool)
    }

    /// A decision to report once the lock is released.
    private struct Change: Sendable {
        var name: EventName
        var level: Event.Level
        var fields: [Event.Field]
    }

    /// Moves open to half-open when its time has come, and gives up on a
    /// probe that has run too long.
    private func refresh(_ core: inout Core, now: AnyClock.Instant, random: RandomSource) -> [Change] {
        switch core.phase {
        case .open(let until?) where now >= until:
            core.generation += 1
            core.phase = .halfOpen
            core.successes = 0
            core.inFlight = [:]
            core.outbox.append(.halfOpen)
            return [Change(name: "breaker.half_open", level: .notice, fields: [
                .init("probes", .int(configuration.halfOpenProbes)),
            ])]
        case .halfOpen:
            guard let oldest = core.inFlight.values.min(),
                  oldest.duration(to: now) >= configuration.halfOpenTimeout else { return [] }
            return trip(&core, now: now, trigger: "probe_timeout", random: random)
        default:
            return []
        }
    }

    private func admit(_ core: inout Core, now: AnyClock.Instant) -> Admission {
        switch core.phase {
        case .closed:
            return .run(Ticket(generation: core.generation, probe: nil))
        case .open(let until):
            let retryAfter = until.map { max(.zero, now.duration(to: $0)) }
            return .reject(Rejection(.circuitOpen, label: label, retryAfter: retryAfter), .open)
        case .halfOpen:
            guard core.successes + core.inFlight.count < configuration.halfOpenProbes else {
                return .reject(Rejection(.circuitOpen, label: label), .halfOpen)
            }
            let id = core.nextProbe
            core.nextProbe += 1
            core.inFlight[id] = now
            return .run(Ticket(generation: core.generation, probe: id))
        }
    }

    /// What a finished call says about the dependency.
    private func judge<R, Failure: Error>(
        _ result: Result<R, Failure>, duration: Duration, callerCancelled: Bool
    ) -> Verdict {
        let slow = duration > configuration.slowCallDuration
        switch result {
        case .success:
            return .recorded(failed: false, slow: slow)
        case .failure(let error):
            if containsDefect(error) { return .ignored("defect") }
            if callerCancelled { return .ignored("cancelled") }
            let inner = error.strippingPolicyLayers
            let failed = configuration.recordWhen(inner)
            if inner is Rejection && !failed { return .ignored("rejection") }
            return .recorded(failed: failed, slow: slow)
        }
    }

    private func complete(
        _ core: inout Core, ticket: Ticket, verdict: Verdict, now: AnyClock.Instant, random: RandomSource
    ) -> [Change] {
        guard ticket.generation == core.generation else {
            return [Change(name: "breaker.ignored", level: .debug, fields: [
                .init("reason", .string("stale"), privacy: .public),
            ])]
        }
        if let probe = ticket.probe { core.inFlight.removeValue(forKey: probe) }

        switch verdict {
        case .ignored(let reason):
            let defect = reason == "defect"
            return [Change(
                name: defect ? "breaker.defect" : "breaker.ignored", level: defect ? .error : .debug,
                fields: [.init("reason", .string(reason), privacy: .public)]
            )]

        case .recorded(let failed, let slow):
            let recorded = Change(name: "breaker.recorded", level: .debug, fields: [
                .init("outcome", .string(failed ? "failure" : "success"), privacy: .public),
                .init("slow", .bool(slow)),
                .init("state", .string(core.phase.state.description), privacy: .public),
            ])

            if ticket.probe != nil {
                // A slow probe is as bad as a failed one: the dependency has
                // not recovered if it still cannot answer in time.
                if failed || slow {
                    return [recorded] + trip(&core, now: now, trigger: failed ? "probe_failed" : "probe_slow", random: random)
                }
                core.successes += 1
                if core.successes >= configuration.halfOpenProbes {
                    return [recorded] + closeNow(&core, now: now, reason: "probes_succeeded")
                }
                return [recorded]
            }

            core.window.record(failed: failed, slow: slow, at: now)
            let totals = core.window.totals(at: now)
            guard totals.calls >= configuration.minimumCalls else { return [recorded] }
            if totals.failureRate(atLeast: failurePPM) {
                return [recorded] + trip(&core, now: now, trigger: "failure_rate", random: random)
            }
            if totals.slowCallRate(atLeast: slowPPM) {
                return [recorded] + trip(&core, now: now, trigger: "slow_calls", random: random)
            }
            return [recorded]
        }
    }

    /// Opens the breaker after a judgement, for the next period in the growth.
    private func trip(_ core: inout Core, now: AnyClock.Instant, trigger: String, random: RandomSource) -> [Change] {
        // Growth continues across closes; only a long stretch of health,
        // measured from the last close, starts it over. A trip from half-open
        // is part of the same bad stretch.
        if case .closed = core.phase, core.closedAt.duration(to: now) >= configuration.openDuration.resetAfter {
            core.trips = 0
        }
        let trip = core.trips
        core.trips += 1
        var generator = random.generator(discriminator: UInt64(trip), fileID: fileID, line: line)
        let jitter = configuration.openDuration.jitter
        var openFor = configuration.openDuration.base(forTrip: trip)
        if jitter > 0 {
            let fraction = Double.random(in: 0..<1, using: &generator)
            openFor = openFor.saturatingMultiplied(by: 1 - jitter * fraction)
        }
        let totals = core.window.totals(at: now)
        return open(&core, now: now, until: now.advanced(by: openFor), trigger: trigger, totals: totals, openFor: openFor)
    }

    private func open(
        _ core: inout Core, now: AnyClock.Instant, until: AnyClock.Instant?,
        trigger: String, totals: OutcomeWindow.Totals, openFor: Duration?
    ) -> [Change] {
        core.generation += 1
        core.phase = .open(until: until)
        core.window.clear()
        core.successes = 0
        core.inFlight = [:]
        core.outbox.append(.open)
        var fields: [Event.Field] = [
            .init("trigger", .string(trigger), privacy: .public),
            .init("calls", .int(totals.calls)),
            .init("failures", .int(totals.failures)),
            .init("slow_calls", .int(totals.slowCalls)),
            .init("trips", .int(core.trips)),
        ]
        if let openFor { fields.append(.init("open_for", .duration(openFor))) }
        return [Change(name: "breaker.opened", level: .warning, fields: fields)]
    }

    private func closeNow(_ core: inout Core, now: AnyClock.Instant, reason: String) -> [Change] {
        let wasClosed: Bool
        if case .closed = core.phase { wasClosed = true } else { wasClosed = false }
        core.generation += 1
        core.phase = .closed
        core.window.clear()
        core.successes = 0
        core.inFlight = [:]
        core.closedAt = now
        guard !wasClosed else { return [] }
        core.outbox.append(.closed)
        return [Change(name: "breaker.closed", level: .notice, fields: [
            .init("reason", .string(reason), privacy: .public),
        ])]
    }

    // MARK: Reporting

    /// Reports what happened under the lock, then publishes the states
    /// entered, in order.
    private func finish(_ changes: [Change]) {
        for change in changes {
            Ambient.record(Event(change.name, level: change.level, label: label, fields: change.fields))
        }
        publish()
    }

    private func publish() {
        let pending = core.withLock { !$0.outbox.isEmpty }
        guard pending else { return }
        publishing.withLock { _ in
            while true {
                let batch = core.withLock { core -> [State] in
                    defer { core.outbox.removeAll() }
                    return core.outbox
                }
                if batch.isEmpty { return }
                let listeners = subscribers.withLock { Array($0.continuations.values) }
                for state in batch {
                    for listener in listeners { listener.yield(state) }
                }
            }
        }
    }

    public var description: String {
        let snapshot = self.snapshot
        return "CircuitBreaker(\(label): \(snapshot.state), \(snapshot.failures)/\(snapshot.calls) failed, \(snapshot.trips) trips)"
    }
}
