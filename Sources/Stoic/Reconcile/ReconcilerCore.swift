/// What a reconciler knows about one key that has not converged.
struct ReconcileKeyState<Key: Hashable & Sendable>: Sendable {
    /// Passes in a row it did not converge: a failed correction, or one that
    /// did not take.
    var streak = 0
    var reason: ReconcileStuck<Key>.Reason?
    var kind: CorrectionKind?
    /// It is not corrected again before this.
    var waitUntil: AnyClock.Instant?
    var stepper: Schedule.Stepper?
    /// A correction returned success, and no reading has seen the result yet.
    var awaitingVerification = false
    /// When it became stuck.
    var stuckSince: Moment?
}

/// What a pass may do, decided from its reading before any correction.
struct ReconcileSelection<Key: Hashable & Sendable>: Sendable {
    /// The corrections to apply, in plan order.
    let run: [PlannedCorrection<Key>]
    let differences: Int
    let waiting: Int
    let held: Int
    /// Beyond `correctionsPerPass`.
    let overLimit: Int
    /// The reason given to the confirmation this pass used.
    let confirmation: String?
}

/// Where the loop goes next.
enum LoopDecision<Key: Hashable & Sendable>: Sendable {
    case pass(NextPass<Key>)
    case sleep(until: AnyClock.Instant?)
}

/// A reconciler's state, behind its `Mutex`: what it knows of the two sides,
/// and what its loop owes. Every method is synchronous; none is called across
/// an `await`.
struct ReconcilerCore<Key: Hashable & Comparable & Sendable>: Sendable {
    // MARK: Knowledge

    /// Keys whose latest reading differed, and keys corrected and not yet
    /// read back.
    var differences: Set<Key> = []
    /// A job's differences that have no key: what it deferred.
    var jobDeferred = 0
    var keys: [Key: ReconcileKeyState<Key>] = [:]
    var hold: RemovalHold<Key>?
    var confirmation: ReconcileConfirmation<Key>?
    var unreadable: (side: ReconcileSide, failure: ReconcileFailure)?
    var hasFullRead = false
    var lastConverged: Moment?
    var lastFullPass: Moment?
    /// The derived keys the last full pass read: the measure a scoped pass's
    /// removals are judged against.
    var lastFullDerived = 0
    /// The moment of this pass's reading, until the pass ends.
    var readAt: Moment?
    let started: Moment
    let overdueAfter: Duration
    var overdueReported = false
    var published: ReconcilerStatus<Key>

    // MARK: What the loop owes

    var running = false
    var pending: Set<Key> = []
    var fullRequested = false
    /// When the triggers (and a full pass request) fall due: `coalesce` after
    /// the latest, and no later than `coalesceAtMost` after `triggerSince`.
    var triggerDue: AnyClock.Instant?
    /// When the oldest trigger not yet served arrived: a pass follows no
    /// later than `coalesceAtMost` after it, however many arrive behind it.
    var triggerSince: AnyClock.Instant?
    var verify: Set<Key> = []
    var verifyDue: AnyClock.Instant?
    var scheduleDue: AnyClock.Instant?
    var failedDue: AnyClock.Instant?
    var failedStepper: Schedule.Stepper?
    var scheduleStepper: Schedule.Stepper?
    var dueIgnored = false

    init(started: Moment, overdueAfter: Duration) {
        self.started = started
        self.overdueAfter = overdueAfter
        published = ReconcilerStatus(
            phase: .starting, lastConverged: nil, lastFullPass: nil, stuck: [], hold: nil, unreadable: nil,
            overdueAt: started + overdueAfter)
    }

    // MARK: The status

    var phase: ReconcilerStatus<Key>.Phase {
        if let unreadable { return .unreadable(unreadable.side) }
        let count = differences.count + jobDeferred
        if hold != nil { return .held(differences: count) }
        if keys.values.contains(where: { $0.stuckSince != nil }) { return .stuck(differences: count) }
        guard hasFullRead else { return .starting }
        return count > 0 ? .converging(differences: count) : .converged
    }

    var status: ReconcilerStatus<Key> {
        let stuck = keys.compactMap { key, state -> ReconcileStuck<Key>? in
            guard let since = state.stuckSince, let reason = state.reason else { return nil }
            return ReconcileStuck(key: key, kind: state.kind, reason: reason, passes: state.streak, since: since)
        }.sorted { $0.key < $1.key }
        return ReconcilerStatus(
            phase: phase, lastConverged: lastConverged, lastFullPass: lastFullPass, stuck: stuck, hold: hold,
            unreadable: unreadable?.failure, overdueAt: (lastFullPass ?? started) + overdueAfter)
    }

    /// Keys holding back on their backoff at `now`.
    func waiting(at now: AnyClock.Instant) -> Set<Key> {
        Set(keys.compactMap { key, state in (state.waitUntil.map { $0 > now } ?? false) ? key : nil })
    }

    // MARK: The loop

    /// What a pass of `scope` covers leaves the queue as it starts.
    mutating func take(_ scope: ReconcileScope<Key>, at now: AnyClock.Instant) {
        switch scope {
        case .all:
            pending = []
            fullRequested = false
            triggerDue = nil
            triggerSince = nil
            verify = []
            verifyDue = nil
        case .keys(let covered):
            pending.subtract(covered)
            if pending.isEmpty, !fullRequested {
                triggerDue = nil
                triggerSince = nil
            }
            verify.subtract(covered)
            if verify.isEmpty { verifyDue = nil }
        }
        // A key whose backoff has ended is read now: whatever this pass makes
        // of it (or fails to), it is not due again on that backoff.
        for (key, state) in keys where scope.contains(key) {
            if let wait = state.waitUntil, wait <= now { keys[key]?.waitUntil = nil }
        }
    }

    /// A trigger at `now`: its pass is due once no trigger has arrived for
    /// `coalesce`, and never later than `coalesceAtMost` after the oldest one
    /// not yet served, so triggers that never go quiet are still served.
    mutating func triggered(at now: AnyClock.Instant, policy: ReconcilePolicy) {
        let since = triggerSince ?? now
        triggerSince = since
        triggerDue = min(now.advanced(by: policy.coalesce), since.advanced(by: policy.coalesceAtMost))
    }

    /// Work a pass left: a full pass is due `coalesce` from `now`, or sooner
    /// if a trigger already is.
    mutating func owesFullPass(at now: AnyClock.Instant, policy: ReconcilePolicy) {
        fullRequested = true
        triggerSince = triggerSince ?? now
        let due = now.advanced(by: policy.coalesce)
        triggerDue = triggerDue.map { min($0, due) } ?? due
    }

    /// The next pass due at `now`, or how long to sleep; and whether the
    /// reconciler has just become overdue.
    mutating func decide(
        at now: AnyClock.Instant, moment: Moment, changeAt: AnyClock.Instant?, clock: AnyClock
    ) -> (LoopDecision<Key>, overdue: Bool) {
        let overdueAt = (lastFullPass ?? started) + overdueAfter
        var overdue = false
        if !overdueReported, moment >= overdueAt {
            overdueReported = true
            overdue = true
        }
        if let due = scheduleDue, due <= now {
            dueIgnored = false
            return (.pass(NextPass(scope: .all, cause: .scheduled)), overdue)
        }
        if let due = failedDue, due <= now { return (.pass(NextPass(scope: .all, cause: .failedRetry)), overdue) }
        if fullRequested, let due = triggerDue, due <= now { return (.pass(NextPass(scope: .all, cause: .triggered)), overdue) }
        if let due = changeAt, due <= now { return (.pass(NextPass(scope: .all, cause: .nextChange)), overdue) }
        var scoped: Set<Key> = []
        if let due = triggerDue, due <= now { scoped.formUnion(pending) }
        if let due = verifyDue, due <= now { scoped.formUnion(verify) }
        for (key, state) in keys where differences.contains(key) {
            if let wait = state.waitUntil, wait <= now { scoped.insert(key) }
        }
        if !scoped.isEmpty { return (.pass(NextPass(scope: .keys(scoped), cause: .triggered)), overdue) }

        var earliest: AnyClock.Instant?
        func consider(_ instant: AnyClock.Instant?) {
            guard let instant else { return }
            earliest = earliest.map { min($0, instant) } ?? instant
        }
        consider(scheduleDue)
        consider(failedDue)
        if fullRequested || !pending.isEmpty { consider(triggerDue) }
        consider(changeAt)
        if !verify.isEmpty { consider(verifyDue) }
        for (key, state) in keys where differences.contains(key) { consider(state.waitUntil) }
        if !overdueReported { consider(now.advanced(by: max(.zero, moment.duration(to: overdueAt)))) }
        return (.sleep(until: earliest), overdue)
    }

    // MARK: A keyed pass

    /// The verdicts a reading gives on what earlier passes did, and what this
    /// pass may do: which removals the guard allows, which wait, which run.
    mutating func judge(
        _ reading: KeyedReading<Key>, scope: ReconcileScope<Key>, now: AnyClock.Instant, moment: Moment,
        policy: ReconcilePolicy, faults: ReconcilerFaults, name: String, events: inout [Event]
    ) -> ReconcileSelection<Key> {
        readAt = moment
        let planned = reading.planned
        let differing = Dictionary(planned.map { ($0.key, $0.kind) }, uniquingKeysWith: { first, _ in first })

        // Verdicts. A key a reading finds matching (or in neither reading) is
        // done: its count and backoff are forgotten. A key corrected with
        // success that still differs did not take.
        for (key, state) in keys where scope.contains(key) {
            if let kind = differing[key] {
                guard state.awaitingVerification else { continue }
                keys[key]?.awaitingVerification = false
                setBack(key, reason: .doesNotTake, kind: kind, defect: false, now: now, moment: moment, policy: policy, name: name, events: &events)
            } else {
                if state.stuckSince != nil {
                    events.append(Event("reconciler.unstuck", level: .info, label: name, fields: [
                        .init("key", .string(String(describing: key)), privacy: .private),
                    ]))
                }
                keys[key] = nil
            }
        }
        switch scope {
        case .all:
            differences = Set(differing.keys)
            lastFullDerived = reading.derivedKeys.count
        case .keys(let covered):
            differences = differences.subtracting(covered).union(differing.keys)
        }

        // The guard, over the derived keys read; a scoped pass is measured
        // against the derived side's size at the last full pass too, so the
        // keys a full pass allowed are not held when a few of them are read back.
        let isFull = scope == .all
        let derived = isFull ? reading.derivedKeys.count : max(reading.derivedKeys.count, lastFullDerived)
        let emptyTruth = isFull && reading.truthCount == 0 && !reading.derivedKeys.isEmpty
        var candidates = Set(planned.lazy.filter { $0.kind == .remove }.map(\.key))
        var allowed: Set<Key> = []
        var held: Set<Key> = []
        var used: ReconcileConfirmation<Key>?
        if isFull, let confirmed = confirmation {
            // Used by the next full pass, whether or not it needs it.
            used = confirmed
            confirmation = nil
            allowed = candidates.intersection(confirmed.keys)
            candidates.subtract(confirmed.keys)
        }
        if !isFull, let hold {
            // A standing hold is a person's to lift: a scoped pass does not
            // remove its keys one by one.
            let blocked = candidates.intersection(hold.keys)
            held.formUnion(blocked)
            candidates.subtract(blocked)
        }
        if !candidates.isEmpty {
            if policy.removals.isUnguarded {
                allowed.formUnion(candidates)
            } else if emptyTruth, !faults.contains(.treatsEmptyTruthAsTrue) {
                // An empty full read is the signature of a broken one.
                held.formUnion(candidates)
            } else if let limit = policy.removals.limit(derived: derived), candidates.count > limit {
                held.formUnion(candidates)
            } else {
                allowed.formUnion(candidates)
            }
        }
        if isFull {
            if held.isEmpty {
                if hold != nil, used == nil {
                    events.append(Event("reconciler.hold_released", level: .info, label: name, fields: [
                        .init("removals", .int(hold?.removals ?? 0)),
                    ]))
                }
                hold = nil
            } else if hold?.keys != held.sorted() {
                newHold(held, derived: reading.derivedKeys.count, truthWasEmpty: reading.truthCount == 0, moment: moment, name: name, events: &events)
            }
        } else {
            let fresh = held.subtracting(hold?.keys ?? [])
            if !fresh.isEmpty {
                // Added to the standing hold, which keeps what the full pass
                // that made it found: the measure, and an empty truth.
                newHold(
                    held.union(hold?.keys ?? []), derived: max(derived, hold?.derivedCount ?? 0),
                    truthWasEmpty: hold?.truthWasEmpty ?? false, moment: moment, name: name, events: &events)
            }
        }

        // What runs, in plan order.
        var run: [PlannedCorrection<Key>] = []
        var waiting = 0
        var overLimit = 0
        for correction in planned {
            if correction.kind == .remove, !allowed.contains(correction.key) { continue }
            if let wait = keys[correction.key]?.waitUntil, wait > now {
                waiting += 1
                continue
            }
            guard run.count < policy.correctionsPerPass else {
                overLimit += 1
                continue
            }
            run.append(correction)
        }
        return ReconcileSelection(
            run: run, differences: planned.count, waiting: waiting, held: held.count, overLimit: overLimit, confirmation: used?.because)
    }

    private mutating func newHold(
        _ keys: Set<Key>, derived: Int, truthWasEmpty: Bool, moment: Moment, name: String, events: inout [Event]
    ) {
        let made = RemovalHold(keys: keys.sorted(), derivedCount: derived, truthWasEmpty: truthWasEmpty, since: moment)
        hold = made
        events.append(Event("reconciler.removals_held", level: .warning, label: name, fields: [
            .init("removals", .int(made.removals)),
            .init("derived", .int(made.derivedCount)),
            .init("truth_empty", .bool(made.truthWasEmpty)),
        ]))
    }

    /// A key did not converge this pass: it counts, waits its backoff, and is
    /// stuck after `stuckAfter` in a row (a defect, or a job's refusal, at once).
    mutating func setBack(
        _ key: Key, reason: ReconcileStuck<Key>.Reason, kind: CorrectionKind?, defect: Bool, now: AnyClock.Instant, moment: Moment,
        policy: ReconcilePolicy, name: String, events: inout [Event]
    ) {
        var state = keys[key] ?? ReconcileKeyState()
        state.streak += 1
        state.reason = reason
        state.kind = kind
        var stepper = state.stepper ?? policy.keyBackoff.makeStepper(
            random: Ambient.current.random.generator(discriminator: Ambient.current.random.nextDraw()))
        state.waitUntil = stepper.next(elapsed: .zero).map { now.advanced(by: $0) }
        state.stepper = stepper
        var refused = false
        if case .refused = reason { refused = true }
        if state.stuckSince == nil, defect || refused || state.streak >= policy.stuckAfter {
            state.stuckSince = moment
            var fields: [Event.Field] = [.init("key", .string(String(describing: key)), privacy: .private)]
            if let kind { fields.append(.init("kind", .string(kind.rawValue), privacy: .public)) }
            switch reason {
            case .failing(let failure):
                fields.append(.init("reason", .string("failing"), privacy: .public))
                fields.append(.init("error", .string(failure.errorType), privacy: .public))
                fields.append(.init("reference", .string(failure.reference.description), privacy: .public))
            case .doesNotTake:
                fields.append(.init("reason", .string("does_not_take"), privacy: .public))
            case .refused:
                // The job's words may name the record; they stay out of the event.
                fields.append(.init("reason", .string("refused"), privacy: .public))
            }
            fields.append(.init("passes", .int(state.streak)))
            events.append(Event("reconciler.stuck", level: defect ? .error : .warning, label: name, fields: fields))
        }
        keys[key] = state
    }

    /// What the corrections did, folded into what is known.
    mutating func record(
        _ outcomes: [Int: CorrectionOutcome], of selection: ReconcileSelection<Key>, reading: KeyedReading<Key>,
        scope: ReconcileScope<Key>, now: AnyClock.Instant, moment: Moment, started: Moment, cancelled: Bool, deadlinePassed: Bool,
        policy: ReconcilePolicy, faults: ReconcilerFaults, name: String, events: inout [Event]
    ) -> ReconcilePassReport<Key> {
        var applied = 0
        var failed = 0
        var cutOff = 0
        var corrected: Set<Key> = []
        for correction in selection.run {
            switch outcomes[correction.position] {
            case .applied?:
                applied += 1
                if faults.contains(.doesNotVerify) {
                    differences.remove(correction.key)
                    keys[correction.key] = nil
                } else {
                    keys[correction.key, default: ReconcileKeyState()].awaitingVerification = true
                    corrected.insert(correction.key)
                }
            case .failed(let error, let outcome)?:
                if deadlinePassed, Self.isDeadline(error) {
                    cutOff += 1
                    continue
                }
                failed += 1
                let failure = ReconcileFailure(error)
                events.append(Event("reconciler.correction_failed", level: .notice, label: name, fields: [
                    .init("key", .string(String(describing: correction.key)), privacy: .private),
                    .init("kind", .string(correction.kind.rawValue), privacy: .public),
                    .init("error", .string(failure.errorType), privacy: .public),
                    .init("outcome", .string(outcome), privacy: .public),
                    .init("reference", .string(failure.reference.description), privacy: .public),
                ]))
                setBack(
                    correction.key, reason: .failing(failure), kind: correction.kind, defect: failure.isDefect, now: now, moment: moment,
                    policy: policy, name: name, events: &events)
            case .cancelled?, nil:
                cutOff += 1
            }
        }
        if !corrected.isEmpty {
            verify.formUnion(corrected)
            verifyDue = now.advanced(by: policy.verifyAfter)
        }
        let deferred = selection.overLimit + cutOff
        if deferred > 0, !cancelled {
            // The rest follows after `coalesce`, as a full pass: the guard
            // judges removals over the whole derived side.
            owesFullPass(at: now, policy: policy)
            events.append(Event("reconciler.cut_short", level: .notice, label: name, fields: [
                .init("deferred", .int(deferred)),
                .init("deadline", .bool(deadlinePassed)),
            ]))
        }
        let outcome: ReconcilePassReport<Key>.Outcome =
            if cancelled { .cancelled }
            else if deferred > 0 { .cutShort }
            else if selection.held > 0 { .held }
            else if failed > 0 || selection.waiting > 0 { .partial }
            else if applied > 0 { .corrected }
            else { .clean }
        return ReconcilePassReport(
            scope: scope, started: started, ended: moment, outcome: outcome, differences: selection.differences, applied: applied,
            failed: failed, deferred: deferred, waiting: selection.waiting, held: selection.held, confirmation: selection.confirmation)
    }

    /// Whether a correction's failure is the pass's deadline cutting it off.
    private static func isDeadline(_ error: any Error) -> Bool {
        containsCancellation(error) || firstError(of: Rejection.self, in: error)?.reason == .deadlineExceeded
    }

    // MARK: A job's pass

    mutating func record(
        _ outcome: ReconcileOutcome<Key>, request: ReconcileRequest<Key>, now: AnyClock.Instant, moment: Moment, started: Moment,
        policy: ReconcilePolicy, name: String, events: inout [Event]
    ) -> ReconcilePassReport<Key> {
        readAt = moment
        let scope = request.scope
        // A key the job refused before and no longer names, in what it looked
        // at, has converged. One it was told to skip is as it was.
        for (key, state) in keys where scope.contains(key) && outcome.refused[key] == nil && !request.waiting.contains(key) {
            if state.stuckSince != nil {
                events.append(Event("reconciler.unstuck", level: .info, label: name, fields: [
                    .init("key", .string(String(describing: key)), privacy: .private),
                ]))
            }
            keys[key] = nil
            differences.remove(key)
        }
        for (key, reason) in outcome.refused.sorted(by: { $0.key < $1.key }) {
            differences.insert(key)
            // Named while it waits its backoff: it still is, and the backoff stands.
            if request.waiting.contains(key), keys[key]?.stuckSince != nil {
                keys[key]?.reason = .refused(reason)
                continue
            }
            setBack(key, reason: .refused(reason), kind: nil, defect: false, now: now, moment: moment, policy: policy, name: name, events: &events)
        }
        if scope == .all { hasFullRead = true }
        jobDeferred = outcome.deferred
        if outcome.deferred > 0 {
            owesFullPass(at: now, policy: policy)
            events.append(Event("reconciler.cut_short", level: .notice, label: name, fields: [
                .init("deferred", .int(outcome.deferred)),
                .init("deadline", .bool(false)),
            ]))
        }
        let result: ReconcilePassReport<Key>.Outcome =
            if outcome.deferred > 0 { .cutShort }
            else if !outcome.refused.isEmpty { .partial }
            else if outcome.corrected > 0 { .corrected }
            else if outcome.differences > 0 { .partial }
            else { .clean }
        return ReconcilePassReport(
            scope: scope, started: started, ended: moment, outcome: result, differences: outcome.differences,
            applied: outcome.corrected, failed: 0, deferred: outcome.deferred, waiting: request.waiting.count, held: 0, confirmation: nil)
    }

    // MARK: After every pass

    /// The status after a pass, the loop's next dues, and the events a change
    /// of phase owes.
    mutating func afterPass(
        scope: ReconcileScope<Key>, cause: PassCause, result: PassResult<Key>, endedAt: AnyClock.Instant, ended: Moment,
        policy: ReconcilePolicy, schedule: Schedule, name: String, events: inout [Event]
    ) {
        let before = published.phase
        var reading: ReconcilePassReport<Key>?
        switch result {
        case .unreadable(let side, let failure):
            unreadable = (side, failure)
            var stepper = failedStepper ?? policy.failedPassBackoff.makeStepper(
                random: Ambient.current.random.generator(discriminator: Ambient.current.random.nextDraw()))
            let delay = stepper.next(elapsed: .zero) ?? .zero
            failedStepper = stepper
            failedDue = endedAt.advanced(by: nextScheduleDelay(schedule, peek: true).map { min(delay, $0) } ?? delay)
        case .read(let report):
            reading = report
            unreadable = nil
            failedStepper = nil
            failedDue = nil
            // A full pass that read both sides knows the differences, even if
            // it was cancelled before it corrected them all.
            if scope == .all {
                hasFullRead = true
                lastFullPass = readAt ?? ended
                overdueReported = false
            }
        case .cancelled:
            break
        }
        if scope == .all, !result.isCancelled {
            scheduleDue = nextScheduleDelay(schedule, peek: false).map { endedAt.advanced(by: $0) }
        }
        let after = phase
        if let reading, after == .converged {
            lastConverged = readAt ?? ended
            if before != .converged {
                events.append(Event("reconciler.converged", level: .info, label: name, fields: [
                    .init("differences", .int(reading.differences)),
                ]))
            }
        }
        if scope == .all, before == .converged, let reading, reading.differences > 0 {
            // Something changed a side without a trigger: a missing `changed`
            // call, or an outside writer.
            events.append(Event("reconciler.drift_found", level: .notice, label: name, fields: [
                .init("differences", .int(reading.differences)),
            ]))
        }
        readAt = nil
        published = status
    }

    /// The schedule's next delay, or `nil` once a bounded schedule has ended;
    /// `peek` reads it without moving the schedule on (a failed pass's backoff
    /// is never longer than it).
    private mutating func nextScheduleDelay(_ schedule: Schedule, peek: Bool) -> Duration? {
        var stepper = scheduleStepper ?? schedule.makeStepper(
            random: Ambient.current.random.generator(discriminator: Ambient.current.random.nextDraw()))
        if peek {
            var copy = stepper
            scheduleStepper = stepper
            return copy.next(elapsed: .zero)
        }
        let delay = stepper.next(elapsed: .zero)
        scheduleStepper = stepper
        return delay
    }
}

extension PassResult {
    var isCancelled: Bool {
        switch self {
        case .cancelled: true
        case .read(let report): report.outcome == .cancelled
        case .unreadable: false
        }
    }
}
