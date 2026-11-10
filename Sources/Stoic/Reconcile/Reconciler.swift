internal import Synchronization
public import Observation

/// Runs a reconciliation: passes on a schedule and on demand, guarded,
/// bounded and observed (design/30).
///
/// It is level-triggered: a full pass is what makes the result correct, and a
/// trigger after a change only makes it prompt. A pass is safe to run at any
/// time, twice, or only partly. A failed read never deletes anything. A pass
/// that would remove an unusual share of the derived side waits for a person
/// to confirm it. Whether the two sides agree is ``status``, which a screen
/// or a health check reads, and it is reported as events.
///
///     let attendees = Reconciler(CalendarAttendees(db: db, calendar: cronofy))
///     let derived = Supervisor(label: "kindora.derived") {
///         Child("calendar-attendees") { _ in try await attendees.run() }
///     }
///     attendees.changed(commitment.eventID)      // prompt; the next full pass is what makes it right
///
/// **One pass at a time.** `run()`'s passes, a background job's `pass()` and a
/// test's queue on one lock, so a key is never corrected by two passes at once.
/// Two reconcilers over one derived side, in one process or in two, are not
/// prevented: they waste work and make corrections that verification
/// settles, and neither removes past its guard (Not built: leases).
public final class Reconciler<Key: Hashable & Comparable & Sendable>: Sendable, Observable {
    /// The reconciliation's name: the label of its events.
    public let name: String

    let policy: ReconcilePolicy
    let schedule: Schedule
    let clock: AnyClock
    let wallClock: WallClock
    let engine: ReconcileEngine<Key>
    let faults: ReconcilerFaults

    private let core: Mutex<ReconcilerCore<Key>>
    private let passLock: AsyncMutex
    private let runLock: AsyncMutex
    private let bell = Doorbell()
    /// Passes ended and loop sleeps, for tests to wait on.
    let progress = ReconcilerProgress()
    private let registrar = ObservationRegistrar()
    // Built once: a key path into a generic class is otherwise rebuilt, and its
    // generic arguments demangled, every time its literal is evaluated.
    private let statusKeyPath: any KeyPath<Reconciler, ReconcilerStatus<Key>> & Sendable = \.status

    init(
        name: String, schedule: Schedule, policy: ReconcilePolicy, clock: AnyClock?, engine: ReconcileEngine<Key>,
        faults: ReconcilerFaults = []
    ) {
        precondition(policy.correctionsPerPass >= 1, "reconciler \(name): correctionsPerPass must be at least one")
        precondition(policy.concurrency >= 1, "reconciler \(name): concurrency must be at least one")
        precondition(policy.stuckAfter >= 1, "reconciler \(name): stuckAfter must be at least one")
        precondition(policy.pendingKeys >= 1, "reconciler \(name): pendingKeys must be at least one")
        precondition(policy.coalesceAtMost >= policy.coalesce, "reconciler \(name): coalesceAtMost must not be shorter than coalesce")
        self.name = name
        self.schedule = schedule
        self.policy = policy
        self.clock = clock ?? Ambient.current.clock
        self.wallClock = Ambient.current.wallClock
        self.engine = engine
        self.faults = faults
        let started = wallClock.now
        core = Mutex(ReconcilerCore(started: started, overdueAfter: policy.overdueAfter))
        passLock = AsyncMutex(label: "reconciler.\(name).pass")
        runLock = AsyncMutex(label: "reconciler.\(name).run")
    }

    /// A reconciler over `reconciliation`'s two sides.
    ///
    /// - Parameters:
    ///   - reconciliation: The declaration, with the clients it reads and
    ///     writes through.
    ///   - schedule: How long after a full pass ends the next one runs: 15
    ///     minutes with equal jitter (7.5 to 15) by default.
    ///   - policy: The guard, the bounds and the backoffs.
    ///   - clock: What it waits on; the ambient clock by default.
    /// - Precondition: Both reads are `.readOnly` and the correction is
    ///   `.idempotent` or `.keyed`: only a repeatable operation can correct,
    ///   and the operations are static declarations, so this is code, not
    ///   input.
    public convenience init<R: Reconciliation>(
        _ reconciliation: R,
        every schedule: Schedule = .fixed(.seconds(900)).jittered(.equal),
        policy: ReconcilePolicy = ReconcilePolicy(),
        clock: AnyClock? = nil
    ) where R.Key == Key {
        self.init(reconciliation, every: schedule, policy: policy, clock: clock, faults: [])
    }

    /// The keyed reconciler, with defects built in for the tests that must
    /// fail (design/30, Testing).
    convenience init<R: Reconciliation>(
        _ reconciliation: R, every schedule: Schedule, policy: ReconcilePolicy, clock: AnyClock?, faults: ReconcilerFaults
    ) where R.Key == Key {
        precondition(R.readsTruth.safety == .readOnly, "reconciliation \(R.name): readsTruth must be .readOnly, not \(R.readsTruth.safety)")
        precondition(R.readsDerived.safety == .readOnly, "reconciliation \(R.name): readsDerived must be .readOnly, not \(R.readsDerived.safety)")
        precondition(
            R.corrects.safety == .idempotent || R.corrects.safety == .keyed,
            "reconciliation \(R.name): corrects must be .idempotent or .keyed, not \(R.corrects.safety): a correction runs again")
        self.init(
            name: R.name, schedule: schedule, policy: policy, clock: clock,
            engine: .keyed(KeyedEngine(reconciliation, faults: faults)), faults: faults)
    }

    /// A reconciler over a job that converges in one call of its own: the
    /// same records, behind where they should be (a lifecycle store's due
    /// timeouts, design/27; zoned values' instants, design/26).
    ///
    /// The runner gives the job everything but the plan: the schedule, the
    /// triggers, the pass deadline, non-overlap, the status, events, the
    /// keys it refuses becoming stuck, and `nextDue`. The job keeps the
    /// contract's promises itself: every read and write a declared operation,
    /// every write repeatable, no removals (a job that removes needs a keyed
    /// reconciliation and its guard). A job that throws is a pass that could
    /// not read: the status says `.unreadable(.truth)`. So is a job that the
    /// pass deadline cuts off: what it did is not known.
    ///
    /// - Parameters:
    ///   - name: Stable forever: the label of its events.
    ///   - schedule: How long after a full pass ends the next one runs.
    ///   - policy: The bounds and backoffs; the guard does not apply.
    ///   - clock: What it waits on; the ambient clock by default.
    ///   - nextDue: When the job next has work by itself: a pass runs then.
    ///   - pass: One pass of the job.
    public convenience init(
        name: String,
        every schedule: Schedule = .fixed(.seconds(900)).jittered(.equal),
        policy: ReconcilePolicy = ReconcilePolicy(),
        clock: AnyClock? = nil,
        nextDue: (@Sendable () async -> Moment?)? = nil,
        pass: @escaping @Sendable (ReconcileRequest<Key>) async throws -> ReconcileOutcome<Key>
    ) {
        self.init(name: name, schedule: schedule, policy: policy, clock: clock, engine: .job(JobEngine(pass: pass, nextDue: nextDue)))
    }

    // MARK: Reading

    /// Whether the two sides agree.
    ///
    /// Observable: a view or a health check that reads it is updated after
    /// every pass, and never in the middle of one. An observer that is not a
    /// view uses `Observations { reconciler.status }`.
    public var status: ReconcilerStatus<Key> {
        registrar.access(self, keyPath: statusKeyPath)
        return core.withLock { $0.published }
    }

    // MARK: Triggers

    /// These keys may have changed: a scoped pass over them follows once no
    /// new keys have arrived for `coalesce`, and no later than
    /// `coalesceAtMost` after the oldest key not yet served, so a side that
    /// changes all day is still corrected promptly.
    ///
    /// Only recorded while `run()` is not running: the next `run()` begins
    /// with a full pass, which covers them.
    public func changed(_ keys: some Sequence<Key>) {
        let now = clock.now
        let overflow = core.withLock { core -> Int? in
            core.pending.formUnion(keys)
            core.triggered(at: now, policy: policy)
            guard core.pending.count > policy.pendingKeys else { return nil }
            defer {
                core.pending = []
                core.fullRequested = true
            }
            return core.pending.count
        }
        if let overflow {
            Ambient.record(Event("reconciler.pending_overflow", level: .notice, label: name, fields: [
                .init("pending", .int(overflow)),
            ]))
        }
        bell.ring()
    }

    /// This key may have changed.
    public func changed(_ key: Key) {
        changed(CollectionOfOne(key))
    }

    /// A full pass follows after `coalesce`, whatever the schedule says: call
    /// it when an app comes back to the foreground, whose suspended loop ran
    /// no schedule.
    public func requestFullPass() {
        let now = clock.now
        core.withLock { core in
            core.fullRequested = true
            core.triggered(at: now, policy: policy)
        }
        bell.ring()
    }

    /// Lets the next full pass make the removals `hold` names, on a person's
    /// word: removing a share of a derived system is an act someone
    /// authorised, and the event records that a principal confirmed.
    ///
    /// The next full pass may remove any key of the hold, and as many others
    /// as the guard allows; beyond that it holds again. It follows after
    /// `coalesce`. Holds and confirmations live in memory: after a relaunch
    /// the next pass holds again and a person confirms again.
    ///
    /// - Parameters:
    ///   - hold: The hold the person saw (``ReconcilerStatus/hold``).
    ///   - principal: Who confirmed it. An app with no accounts declares its
    ///     own evidence ("the person at this device confirmed").
    ///   - because: Why, in their words. Kept in the pass's report; never put
    ///     in an event.
    /// - Throws: ``ReconcileError/holdChanged`` when `hold` is not the current
    ///   one: a person never confirms a list they did not see.
    public func confirm<Principal, E: PrincipalEvidence>(
        _ hold: RemovalHold<Key>, by principal: Verified<Principal, E>, because: String
    ) throws(ReconcileError) {
        let accepted = core.withLock { core -> Bool in
            guard core.hold == hold else { return false }
            core.confirmation = ReconcileConfirmation(keys: Set(hold.keys), because: because)
            return true
        }
        guard accepted else { throw .holdChanged }
        Ambient.record(Event("reconciler.removals_confirmed", level: .notice, label: name, fields: [
            .init("removals", .int(hold.removals)),
            .init("principal", .string(String(describing: principal.value)), privacy: .private),
            .init("evidence", .string(String(describing: E.self)), privacy: .public),
        ]))
        requestFullPass()
    }

    // MARK: Passes

    /// One pass now, after any pass in progress, at the caller's urgency and
    /// under the earlier of the caller's deadline and `passDeadline`.
    ///
    /// The pass in progress started before whatever made the caller ask, so
    /// the caller waits for it and then runs its own, waiting no longer than
    /// its own deadline.
    ///
    /// - Returns: What it did.
    /// - Throws: ``ReconcileError/unreadable(_:_:)`` when a side could not be
    ///   read (a background job reports failure to the system);
    ///   ``ReconcileError/cancelled`` when the pass, or the wait for the one in
    ///   progress, was cancelled. What a cancelled pass finished stands.
    @concurrent
    @discardableResult
    public func pass(_ scope: ReconcileScope<Key> = .all) async throws(ReconcileError) -> ReconcilePassReport<Key> {
        let result = try await exclusive { await self.runPass(scope, cause: .requested) }
        bell.ring()
        switch result {
        case .read(let report):
            if report.outcome == .cancelled { throw .cancelled }
            return report
        case .unreadable(let side, let failure):
            throw .unreadable(side, failure)
        case .cancelled:
            throw .cancelled
        }
    }

    /// Passes until cancelled: one full pass at once, then on the schedule,
    /// on triggers, for verification, at a key's backoff and at
    /// `nextChange()` (or a job's `nextDue`), at `policy.urgency`.
    ///
    /// A pass that fails is a status, never a throw: a truth that cannot be
    /// read is `.unreadable`, and a supervisor's restart would only read it
    /// again. A second `run()` while one runs waits for it to end.
    ///
    /// - Throws: `CancellationError` when cancelled; the pass in progress is
    ///   cancelled, and what it finished stands.
    @concurrent
    public func run() async throws(CancellationError) {
        do throws(PolicyError<CancellationError>) {
            try await runLock.withLock { () async throws(CancellationError) in
                try await withUrgency(policy.urgency) { () async throws(CancellationError) in
                    try await loop()
                }
            }
        } catch {
            throw CancellationError()
        }
    }

    // MARK: The loop

    private func loop() async throws(CancellationError) {
        // Triggers recorded while nothing ran are covered by the first pass.
        core.withLock { core in
            core.running = true
            core.pending = []
            core.fullRequested = false
            core.triggerDue = nil
            core.triggerSince = nil
        }
        defer { core.withLock { $0.running = false } }
        var next = NextPass<Key>(scope: .all, cause: .start)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let result: PassResult<Key>
            do throws(ReconcileError) {
                result = try await exclusive { await self.runPass(next.scope, cause: next.cause) }
            } catch {
                throw CancellationError()
            }
            if case .cancelled = result { throw CancellationError() }
            if next.cause == .nextChange { await checkDueMoved() }
            next = try await waitForNextPass()
        }
    }

    /// A due moment that is still not in the future after the pass it caused
    /// is ignored until the next scheduled pass, so a defective `nextDue`
    /// cannot make the loop spin.
    private func checkDueMoved() async {
        guard let due = await engine.nextChange(), due <= wallClock.now else { return }
        let newly = core.withLock { core -> Bool in
            defer { core.dueIgnored = true }
            return !core.dueIgnored
        }
        if newly {
            Ambient.record(Event("reconciler.due_ignored", level: .warning, label: name, fields: [
                .init("due", .string(due.description), privacy: .public),
            ]))
        }
    }

    /// Sleeps until a pass is due, and says which.
    private func waitForNextPass() async throws(CancellationError) -> NextPass<Key> {
        while true {
            if Task.isCancelled { throw CancellationError() }
            let change = core.withLock { $0.dueIgnored } ? nil : await engine.nextChange()
            let now = clock.now
            let moment = wallClock.now
            // A moment is a wait on the reconciler's clock, recomputed every
            // time the loop goes to sleep: after a wall-clock jump the error
            // is bounded by the next scheduled pass.
            let changeAt = change.map { now.advanced(by: max(.zero, moment.duration(to: $0))) }
            let (decision, overdue) = core.withLock { core in
                core.decide(at: now, moment: moment, changeAt: changeAt, clock: clock)
            }
            if overdue { reportOverdue() }
            switch decision {
            case .pass(let next):
                return next
            case .sleep(let until):
                progress.note(.sleeps)
                try await bell.wait(until: until, clock: clock)
            }
        }
    }

    private func reportOverdue() {
        let since = core.withLock { $0.lastFullPass }
        Ambient.record(Event("reconciler.overdue", level: .warning, label: name, fields: [
            .init("since", .string(since?.description ?? "start"), privacy: .public),
            .init("after", .duration(policy.overdueAfter)),
        ]))
    }

    /// `body` holding the pass lock: passes never overlap.
    private func exclusive(
        _ body: () async -> PassResult<Key>
    ) async throws(ReconcileError) -> PassResult<Key> {
        if faults.contains(.letsPassesOverlap) { return await body() }
        do throws(PolicyError<Never>) {
            return try await passLock.withLock { await body() }
        } catch {
            throw .cancelled
        }
    }

    // MARK: One pass

    private func runPass(_ scope: ReconcileScope<Key>, cause: PassCause) async -> PassResult<Key> {
        let started = wallClock.now
        let startedAt = clock.now
        let deadline = Deadline.after(policy.passDeadline, clock: clock).narrowedByCurrent
        // What this pass covers leaves the queue now: triggers that arrive
        // while it runs are folded into the next one.
        core.withLock { core in core.take(scope, at: startedAt) }
        var events: [Event] = []
        let result: PassResult<Key>
        switch engine {
        case .keyed(let keyed):
            result = await keyedPass(keyed, scope: scope, started: started, deadline: deadline, events: &events)
        case .job(let job):
            result = await jobPass(job, scope: scope, started: started, deadline: deadline, events: &events)
        }
        let ended = wallClock.now
        let endedAt = clock.now
        core.withLock { core in
            core.afterPass(
                scope: scope, cause: cause, result: result, endedAt: endedAt, ended: ended, policy: policy, schedule: schedule,
                name: name, events: &events)
        }
        if case .read(let report) = result {
            events.append(Event("reconciler.pass_ended", level: .debug, label: name, fields: [
                .init("scope", .string(Self.describe(scope)), privacy: .public),
                .init("outcome", .string(report.outcome.description), privacy: .public),
                .init("differences", .int(report.differences)),
                .init("applied", .int(report.applied)),
                .init("failed", .int(report.failed)),
                .init("deferred", .int(report.deferred)),
                .init("waiting", .int(report.waiting)),
                .init("held", .int(report.held)),
                .init("duration", .duration(startedAt.duration(to: endedAt))),
            ]))
        }
        // Outside every lock: neither an observer nor a sink can deadlock it.
        registrar.withMutation(of: self, keyPath: statusKeyPath) {}
        for event in events { Ambient.record(event) }
        progress.note(.passes)
        return result
    }

    static func describe(_ scope: ReconcileScope<Key>) -> String {
        switch scope {
        case .all: "all"
        case .keys(let keys): "keys(\(keys.count))"
        }
    }

    // MARK: A keyed pass

    private func keyedPass(
        _ keyed: KeyedEngine<Key>, scope: ReconcileScope<Key>, started: Moment, deadline: Deadline,
        events: inout [Event]
    ) async -> PassResult<Key> {
        let reading: KeyedReading<Key>
        switch await keyed.read(scope, deadline) {
        case .cancelled:
            return .cancelled
        case .unreadable(let side, let error):
            let failure = ReconcileFailure(error)
            events.append(Event("reconciler.unreadable", level: .warning, label: name, fields: [
                .init("side", .string(side.rawValue), privacy: .public),
                .init("error", .string(failure.errorType), privacy: .public),
                .init("reference", .string(failure.reference.description), privacy: .public),
            ]))
            return .unreadable(side, failure)
        case .read(let read):
            reading = read
        }
        for (side, count) in reading.outsideScope where count > 0 {
            events.append(Event("reconciler.scope_exceeded", level: .error, label: name, fields: [
                .init("side", .string(side.rawValue), privacy: .public),
                .init("keys", .int(count)),
            ]))
        }
        let readAt = wallClock.now
        let now = clock.now

        // Verdicts on what earlier passes did, then what this one may do.
        let selection = core.withLock { core in
            core.judge(
                reading, scope: scope, now: now, moment: readAt, policy: policy, faults: faults, name: name, events: &events)
        }

        // The corrections, in plan order, at most `concurrency` at once.
        let outcomes = await keyed.correct(selection.run, passKey: IdempotencyKey.random(), concurrency: policy.concurrency, deadline: deadline)
        let cancelled = Task.isCancelled

        let report = core.withLock { core in
            core.record(
                outcomes, of: selection, reading: reading, scope: scope, now: clock.now, moment: wallClock.now, started: started,
                cancelled: cancelled, deadlinePassed: deadline.hasPassed, policy: policy, faults: faults, name: name, events: &events)
        }
        return .read(report)
    }

    // MARK: A job's pass

    private func jobPass(
        _ job: JobEngine<Key>, scope: ReconcileScope<Key>, started: Moment, deadline: Deadline, events: inout [Event]
    ) async -> PassResult<Key> {
        let now = clock.now
        let waiting = core.withLock { $0.waiting(at: now) }
        let request = ReconcileRequest(scope: scope, limit: policy.correctionsPerPass, waiting: waiting)
        let outcome: Result<ReconcileOutcome<Key>, any Error> = await withDeadline(deadline) {
            do {
                return .success(try await job.pass(request))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .failure where Task.isCancelled:
            return .cancelled
        case .failure(let error):
            // Nobody cancelled the pass. A job that ends in cancellation all
            // the same was cut off by the pass's deadline (or threw it by
            // itself): what it did is not known, so it is a pass that could
            // not read, tried again on the failed pass backoff. The loop goes
            // on: `run()` ends only when it is cancelled.
            let cutOff = deadline.hasPassed && containsCancellation(error)
            let failure = ReconcileFailure(cutOff ? Rejection(.deadlineExceeded, label: name) : error)
            events.append(Event("reconciler.unreadable", level: .warning, label: name, fields: [
                .init("side", .string(ReconcileSide.truth.rawValue), privacy: .public),
                .init("error", .string(failure.errorType), privacy: .public),
                .init("reference", .string(failure.reference.description), privacy: .public),
            ]))
            return .unreadable(.truth, failure)
        case .success(let outcome):
            let report = core.withLock { core in
                core.record(
                    outcome, request: request, now: clock.now, moment: wallClock.now, started: started, policy: policy, name: name,
                    events: &events)
            }
            return .read(report)
        }
    }
}

/// Defects a reconciler can be built with, for the tests that must fail
/// (design/30, Testing): each disables one of the guarantees, so the harness
/// is shown to catch the real code going wrong, not a copy of it.
struct ReconcilerFaults: OptionSet, Sendable {
    let rawValue: Int
    /// A truth read that fails is read as empty.
    static let removesOnFailedTruthRead = ReconcilerFaults(rawValue: 1 << 0)
    /// An empty truth read beside a derived side is believed.
    static let treatsEmptyTruthAsTrue = ReconcilerFaults(rawValue: 1 << 1)
    /// Passes do not queue on the lock.
    static let letsPassesOverlap = ReconcilerFaults(rawValue: 1 << 2)
    /// A correction that returned success is taken as done, unread.
    static let doesNotVerify = ReconcilerFaults(rawValue: 1 << 3)
}

/// Why a pass runs.
enum PassCause: Sendable, Hashable {
    case start, scheduled, failedRetry, triggered, nextChange, requested
}

/// The pass the loop runs next.
struct NextPass<Key: Hashable & Sendable>: Sendable {
    let scope: ReconcileScope<Key>
    let cause: PassCause
}

/// How a pass ended.
enum PassResult<Key: Hashable & Sendable>: Sendable {
    case read(ReconcilePassReport<Key>)
    case unreadable(ReconcileSide, ReconcileFailure)
    case cancelled
}

/// A person's confirmation of a hold, waiting for the next full pass.
struct ReconcileConfirmation<Key: Hashable & Sendable>: Sendable {
    let keys: Set<Key>
    let because: String
}
