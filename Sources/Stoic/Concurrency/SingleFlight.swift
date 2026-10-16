internal import Synchronization

/// Concurrent requests for the same key share one execution.
///
/// When ten views ask for the same avatar at once, one download should run
/// and ten callers should get its result. The first caller for a key starts
/// the operation; callers that arrive while it runs join it. When it
/// finishes, the key is cleared: this is deduplication, not caching.
///
/// The shared operation belongs to the flight, not to any one caller:
///
/// - **Cancellation is reference-counted.** A caller that is cancelled, or
///   whose ``Deadline/current`` passes, leaves the flight with a rejection;
///   the operation goes on for the others. Only when the last caller has
///   left is the operation cancelled — and the key is retired at once, so a
///   caller arriving after that starts a fresh flight instead of joining one
///   that is winding down.
/// - **No caller's deadline bounds the others.** The operation runs without
///   the first caller's deadline; each caller's wait is bounded by its own.
///   A flight whose callers have all given up is cancelled, so the
///   operation is never orphaned.
/// - **It runs at the most urgent caller's priority.** A caller waits on a
///   continuation, which escalates nothing by itself, so the flight does it:
///   a caller who joins at a higher priority than the flight runs at, or who
///   is escalated while waiting, escalates the shared operation to match. A
///   background prefetch that a tap then joins runs at the tap's priority.
/// - It inherits the first caller's ``Ambient`` context and other task-locals.
///
/// Every caller receives the same value, or the same error.
public final class SingleFlight<Key: Hashable & Sendable, Value: Sendable, Failure: Error>: Sendable {
    /// Names the flight group in events.
    public let label: String

    private typealias Outcome = Result<Value, PolicyError<Failure>>
    private typealias Waiter = CheckedContinuation<Outcome, Never>

    /// Records a flight's outcome where it belongs (a cache's entry) before
    /// any caller sees it. Run only by a flight that is still live.
    typealias Commit = @Sendable (Result<Value, Failure>) async -> Void

    private struct Flight {
        let id: UInt64
        let cause = CancellationCauseBox(parent: nil)
        var task: Task<Void, Never>?
        var waiters: [UInt64: Waiter] = [:]
        /// The most urgent priority a caller has asked for: what the task
        /// must be escalated to, including before it exists.
        var priority: TaskPriority
        /// Committing its outcome: it has finished, so it is no longer
        /// abandoned when its last caller leaves.
        var landing = false
    }

    private struct State {
        var nextID: UInt64 = 0
        var flights: [Key: Flight] = [:]
        // Callers with an id that have not joined a flight yet, with the
        // rejection (cancellation, deadline) that arrived first, if any.
        var arriving: [UInt64: Rejection?] = [:]
        // The key each joined caller is waiting on.
        var membership: [UInt64: Key] = [:]
    }

    private let state = Mutex(State())

    public init(label: String) {
        self.label = label
    }

    /// The number of keys with an operation in flight.
    public var flightCount: Int {
        state.withLock { $0.flights.count }
    }

    /// The number of callers waiting on `key`'s flight.
    public func waiterCount(for key: Key) -> Int {
        state.withLock { $0.flights[key]?.waiters.count ?? 0 }
    }

    /// Runs `operation` for `key`, or joins the run already in flight.
    ///
    /// - Throws: `.failed` with the shared operation's error, or `.rejected`
    ///   when this caller stopped waiting: `.cancelled`, or
    ///   `.deadlineExceeded` when ``Deadline/current`` passed.
    public nonisolated(nonsending) func run(
        _ key: Key,
        operation: @escaping @concurrent @Sendable () async throws(Failure) -> Value
    ) async throws(PolicyError<Failure>) -> Value {
        try await run(key, operation: operation, commit: nil)
    }

    /// ``run(_:operation:)``, with `commit` run once on the outcome before
    /// any caller receives it — if this call starts the flight.
    ///
    /// A flight that every caller left has been cancelled and its key
    /// retired; if its operation finishes anyway, it never commits, so its
    /// outcome cannot overwrite a newer flight's. Once committing has begun
    /// the flight is no longer abandoned: callers that leave just leave, and
    /// callers that arrive join it and receive the committed outcome.
    nonisolated(nonsending) func run(
        _ key: Key,
        operation: @escaping @concurrent @Sendable () async throws(Failure) -> Value,
        commit: Commit?
    ) async throws(PolicyError<Failure>) -> Value {
        if Task.isCancelled { throw .rejected(Rejection(.cancelled, label: label)) }
        let waiterID = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            state.arriving[state.nextID] = .some(nil)
            return state.nextID
        }
        await FaultPoint.hit("singleflight.arriving")
        let deadline = Deadline.current
        // Read here, in the caller: a cancellation handler runs in whoever
        // cancels, and must still say why this caller was cancelled.
        let callerCauses = CancellationCauseBox.current
        // A waiting caller's task can be escalated (something more urgent now
        // awaits it); its continuation would not pass that on, so pass it on.
        let outcome: Outcome = await withTaskPriorityEscalationHandler {
            await withTaskGroup(of: Void.self) { group in
                if let deadline {
                    group.addTask {
                        do {
                            try await deadline.clock.sleep(until: deadline.instant, tolerance: nil)
                            self.leave(waiterID, because: Rejection(.deadlineExceeded, label: self.label), cause: .deadline)
                        } catch {}
                    }
                }
                let outcome = await withTaskCancellationHandler {
                    await withCheckedContinuation { (waiter: Waiter) in
                        join(waiterID, key: key, operation: operation, commit: commit, waiter: waiter)
                    }
                } onCancel: {
                    leave(waiterID, because: Rejection(.cancelled, label: label),
                          cause: CancellationCauseBox.outsideCause(seenBy: callerCauses))
                }
                group.cancelAll()
                return outcome
            }
        } onPriorityEscalated: { old, new in
            self.escalate(waiterID, to: max(old, new))
        }
        if case .failure(.rejected(let rejection)) = outcome,
           rejection.reason == .cancelled, CancellationCause.current == .deadline {
            throw .rejected(Rejection(.deadlineExceeded, label: label))
        }
        return try outcome.get()
    }

    private func join(
        _ waiterID: UInt64,
        key: Key,
        operation: @escaping @concurrent @Sendable () async throws(Failure) -> Value,
        commit: Commit?,
        waiter: Waiter
    ) {
        let (next, priority) = state.withLock { state -> (FlightJoin, TaskPriority) in
            // Read under the lock: an escalation that lands after this finds
            // the caller's membership, set in the same critical section.
            let priority = Task.currentPriority
            return (joinLocked(&state, waiterID, key: key, waiter: waiter, priority: priority), priority)
        }
        switch next {
        case .rejected(let rejection):
            waiter.resume(returning: .failure(.rejected(rejection)))
        case .joined(let escalating):
            // Outside the lock: an escalation runs the operation's own
            // escalation handlers, synchronously.
            escalating?.escalatePriority(to: priority)
            Ambient.record(Event("singleflight.joined", level: .debug, label: label))
        case .launch(let flightID, let priority):
            launch(key: key, flightID: flightID, priority: priority, operation: operation, commit: commit)
        }
    }

    private func joinLocked(_ state: inout State, _ waiterID: UInt64, key: Key, waiter: Waiter, priority: TaskPriority) -> FlightJoin {
        if let early = state.arriving.removeValue(forKey: waiterID) ?? nil {
            return .rejected(early)
        }
        state.membership[waiterID] = key
        if state.flights[key] != nil {
            state.flights[key]!.waiters[waiterID] = waiter
            guard priority > state.flights[key]!.priority else { return .joined(escalating: nil) }
            // The caller escalates a running task; a task not created yet
            // is escalated by its launch, which reads this.
            state.flights[key]!.priority = priority
            return .joined(escalating: state.flights[key]!.task)
        }
        let flightID = state.nextID
        state.nextID += 1
        var flight = Flight(id: flightID, priority: priority)
        flight.waiters[waiterID] = waiter
        state.flights[key] = flight
        return .launch(flightID, priority)
    }

    /// Raises the flight `waiterID` is waiting on to `priority`.
    private func escalate(_ waiterID: UInt64, to priority: TaskPriority) {
        let task = state.withLock { state -> Task<Void, Never>? in
            // Not joined yet: it joins at its current, escalated, priority.
            guard let key = state.membership[waiterID], state.flights[key] != nil,
                  priority > state.flights[key]!.priority else { return nil }
            state.flights[key]!.priority = priority
            return state.flights[key]!.task
        }
        task?.escalatePriority(to: priority)
    }

    private func launch(
        key: Key,
        flightID: UInt64,
        priority launchedAt: TaskPriority,
        operation: @escaping @concurrent @Sendable () async throws(Failure) -> Value,
        commit: Commit?
    ) {
        let cause = state.withLock { $0.flights[key]?.id == flightID ? $0.flights[key]?.cause : nil }
        guard let cause else { return }   // every caller already left
        let task = TaskLedger.task(.flight, label: label) {
            let result: Result<Value, Failure> = await Deadline.$stored.withValue(nil) {
                await CancellationCauseBox.$current.withValue(cause) {
                    do throws(Failure) {
                        return .success(try await operation())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            if let commit, self.beginLanding(key: key, flightID: flightID) {
                await commit(result)
            }
            self.land(key: key, flightID: flightID, result: result)
        }
        let (orphaned, wanted) = state.withLock { state -> (Bool, TaskPriority) in
            guard state.flights[key]?.id == flightID else { return (true, launchedAt) }
            state.flights[key]!.task = task
            return (false, state.flights[key]!.priority)
        }
        // A more urgent caller joined before the task existed.
        if wanted > launchedAt { task.escalatePriority(to: wanted) }
        if orphaned {
            // Every caller left between the flight's creation and its task's;
            // the last one recorded why when it retired the flight.
            task.cancel()
        }
    }

    /// Takes `waiterID` out of its flight. If it was the last caller, the
    /// flight is cancelled, and `cause` (why that caller left) is what the
    /// operation reads as its cancellation cause.
    private func leave(_ waiterID: UInt64, because rejection: Rejection, cause: CancellationCause) {
        let (waiter, retired) = state.withLock { state -> (Waiter?, Flight?) in
            if let arriving = state.arriving[waiterID] {
                // Not joined yet: it will find this on arrival.
                if arriving == nil { state.arriving[waiterID] = .some(rejection) }
                return (nil, nil)
            }
            guard let key = state.membership.removeValue(forKey: waiterID),
                  var flight = state.flights[key],
                  let waiter = flight.waiters.removeValue(forKey: waiterID) else {
                return (nil, nil)
            }
            if flight.waiters.isEmpty, !flight.landing {
                // The last caller left: retire the key now, so newcomers
                // start afresh rather than join a flight being cancelled.
                // The cause is recorded before the flight can be seen
                // retired, so a launch that finds it orphaned cancels a
                // task whose cause is already set.
                state.flights[key] = nil
                flight.cause.record(cause)
                return (waiter, flight)
            }
            state.flights[key] = flight
            return (waiter, nil)
        }
        waiter?.resume(returning: .failure(.rejected(rejection)))
        if let retired {
            retired.task?.cancel()
            Ambient.record(Event("singleflight.abandoned", label: label))
        }
    }

    /// Whether flight `flightID` is still live, and if so marks it landing,
    /// so that it can no longer be abandoned while it commits.
    private func beginLanding(key: Key, flightID: UInt64) -> Bool {
        state.withLock { state in
            guard state.flights[key]?.id == flightID else { return false }
            state.flights[key]!.landing = true
            return true
        }
    }

    private func land(key: Key, flightID: UInt64, result: Result<Value, Failure>) {
        let waiters = state.withLock { state -> [Waiter] in
            guard let flight = state.flights[key], flight.id == flightID else { return [] }
            state.flights[key] = nil
            for waiterID in flight.waiters.keys { state.membership[waiterID] = nil }
            return flight.waiters.valuesInKeyOrder
        }
        let outcome: Outcome = result.mapError { .failed($0) }
        for waiter in waiters { waiter.resume(returning: outcome) }
    }
}

private enum FlightJoin {
    case rejected(Rejection)
    case joined(escalating: Task<Void, Never>?)
    case launch(UInt64, TaskPriority)
}
