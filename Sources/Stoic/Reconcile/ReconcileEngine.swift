internal import Synchronization

/// What a reconciler runs: a keyed reconciliation, whose plan the runner
/// computes and guards, or a job that does its own pass.
enum ReconcileEngine<Key: Hashable & Comparable & Sendable>: Sendable {
    case keyed(KeyedEngine<Key>)
    case job(JobEngine<Key>)

    /// When the truth next changes by itself.
    func nextChange() async -> Moment? {
        switch self {
        case .keyed(let keyed): await keyed.nextChange()
        case .job(let job): await job.nextDue?()
        }
    }
}

/// A job that converges by itself.
struct JobEngine<Key: Hashable & Sendable>: Sendable {
    let pass: @Sendable (ReconcileRequest<Key>) async throws -> ReconcileOutcome<Key>
    let nextDue: (@Sendable () async -> Moment?)?
}

/// How one correction ended.
enum CorrectionOutcome: Sendable {
    case applied
    /// It failed: the error, and what is known of the backend's side.
    case failed(any Error, outcome: String)
    /// It was cancelled before it finished: the pass was, or its deadline passed.
    case cancelled
}

/// One correction of a plan, with what applies it.
struct PlannedCorrection<Key: Hashable & Sendable>: Sendable {
    let key: Key
    let kind: CorrectionKind
    /// Its position in the plan: half of its idempotency key.
    let position: Int
    let apply: @Sendable (IdempotencyKey, Deadline) async -> CorrectionOutcome
}

/// Two complete readings, as the runner sees them: the plan, type-erased.
struct KeyedReading<Key: Hashable & Sendable>: Sendable {
    let planned: [PlannedCorrection<Key>]
    /// Keys the truth's reading held.
    let truthCount: Int
    /// Keys the derived side's reading held.
    let derivedKeys: Set<Key>
    /// Keys each scoped read returned outside its scope (ignored).
    let outsideScope: [(side: ReconcileSide, keys: Int)]
}

enum KeyedReadResult<Key: Hashable & Sendable>: Sendable {
    case read(KeyedReading<Key>)
    case unreadable(ReconcileSide, any Error)
    case cancelled
}

/// A ``Reconciliation`` behind closures, so the runner is generic over the
/// key alone.
struct KeyedEngine<Key: Hashable & Comparable & Sendable>: Sendable {
    let read: @Sendable (ReconcileScope<Key>, Deadline) async -> KeyedReadResult<Key>
    let nextChange: @Sendable () async -> Moment?

    init<R: Reconciliation>(_ reconciliation: R, faults: ReconcilerFaults) where R.Key == Key {
        nextChange = { await reconciliation.nextChange() }
        read = { scope, deadline in
            // The truth first: if it cannot be read, the derived side is never asked.
            await FaultPoint.hit("reconciler.read")
            var desired: [Key: R.Desired]
            switch await Self.perform(R.readsTruth, within: deadline, { attempt throws(R.Failure) in
                try await reconciliation.desired(scope, attempt: attempt)
            }) {
            case .success(let read):
                desired = read
            case .failure(let error):
                if Task.isCancelled || error.isCancellation { return .cancelled }
                guard faults.contains(.removesOnFailedTruthRead) else { return .unreadable(.truth, error) }
                desired = [:]
            }
            await FaultPoint.hit("reconciler.read")
            var actual: [Key: R.Actual]
            switch await Self.perform(R.readsDerived, within: deadline, { attempt throws(R.Failure) in
                try await reconciliation.actual(scope, attempt: attempt)
            }) {
            case .success(let read):
                actual = read
            case .failure(let error):
                if Task.isCancelled || error.isCancellation { return .cancelled }
                return .unreadable(.derived, error)
            }
            // A key outside a scoped read's scope is ignored: the
            // reconciliation is wrong, and it is not trusted to say which keys
            // are removable.
            var outside: [(side: ReconcileSide, keys: Int)] = []
            if case .keys(let keys) = scope {
                let truthBefore = desired.count
                desired = desired.filter { keys.contains($0.key) }
                let derivedBefore = actual.count
                actual = actual.filter { keys.contains($0.key) }
                outside = [(.truth, truthBefore - desired.count), (.derived, derivedBefore - actual.count)]
            }
            let plan = ReconcilePlan(desired: desired, actual: actual, using: reconciliation)
            let planned = plan.corrections.enumerated().map { position, correction in
                PlannedCorrection(key: correction.key, kind: correction.kind, position: position) { key, deadline in
                    await Self.correct(correction, with: reconciliation, key: key, within: deadline)
                }
            }
            return .read(KeyedReading(planned: planned, truthCount: desired.count, derivedKeys: Set(actual.keys), outsideScope: outside))
        }
    }

    /// `operation` under the earlier of its default total deadline (at the
    /// pass's urgency) and what is left of the pass: a pass's deadline must not
    /// stretch one call, which `perform` would otherwise take as its own.
    private static func perform<Value: Sendable, Failure: Error>(
        _ operation: Backend.Operation, within pass: Deadline, key: IdempotencyKey? = nil,
        _ body: @escaping @Sendable (Attempt) async throws(Failure) -> Value
    ) async -> Result<Value, OperationError<Failure>> {
        let own = Deadline.after(operation.policy(at: Urgency.current).deadline, clock: pass.clock)
        return await withDeadline(own.earlier(pass)) { () async -> Result<Value, OperationError<Failure>> in
            do throws(OperationError<Failure>) {
                return .success(try await operation.perform(idempotencyKey: key) { attempt throws(Failure) in try await body(attempt) })
            } catch {
                return .failure(error)
            }
        }
    }

    private static func correct<R: Reconciliation>(
        _ correction: Correction<R.Key, R.Desired, R.Actual>, with reconciliation: R, key: IdempotencyKey, within pass: Deadline
    ) async -> CorrectionOutcome {
        // Every correction is given its key explicitly: corrections run in
        // child tasks, where a derived key is refused (design/22).
        switch await perform(R.corrects, within: pass, key: key, { attempt throws(R.Failure) in
            try await reconciliation.correct(correction, attempt: attempt)
        }) {
        case .success:
            return .applied
        case .failure(let error):
            return error.isCancellation ? .cancelled : .failed(error, outcome: error.outcome.description)
        }
    }

    /// Applies `planned`, in plan order, at most `concurrency` at once, under
    /// the pass's deadline: when it passes, none starts and those in flight
    /// are cancelled. Returns each started correction's outcome by position;
    /// one never started has none.
    func correct(
        _ planned: [PlannedCorrection<Key>], passKey: IdempotencyKey, concurrency: Int, deadline: Deadline
    ) async -> [Int: CorrectionOutcome] {
        guard !planned.isEmpty else { return [:] }
        let outcomes = Mutex<[Int: CorrectionOutcome]>([:])
        do throws(Rejection) {
            _ = try await withDeadline(deadline) { () async throws(Rejection) -> [Result<Void, Never>] in
                try await mapConcurrentResults(planned, limit: concurrency, label: "reconciler.corrections") { correction in
                    await FaultPoint.hit("reconciler.correct")
                    let outcome = await correction.apply(.reconciliation(pass: passKey, position: correction.position), deadline)
                    outcomes.withLock { $0[correction.position] = outcome }
                }
            }
        } catch {
            // Cut short or cancelled: what finished is recorded, and the rest
            // stays a difference for the next pass.
            return outcomes.withLock { $0 }
        }
        return outcomes.withLock { $0 }
    }
}
