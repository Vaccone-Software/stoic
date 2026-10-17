internal import Synchronization

extension Backend.Operation {
    /// Runs `operation` under the policy derived for this call: the
    /// operation's declaration, its backend, who is waiting
    /// (``Urgency/current``) and by when (``Deadline/current``).
    ///
    /// For one call, outermost first (design/22, Order):
    ///
    /// 1. **The default deadline**, when the caller set none: the kind's and
    ///    urgency's total. A caller's deadline, shorter or longer, wins.
    /// 2. **The retry loop**, on the derived schedule, with the backend's
    ///    budget. A failed attempt is classified in order: a ``Defect``
    ///    stops; the caller's cancellation stops (an attempt cut off by its
    ///    own timeout is transient); repeat safety decides whether the
    ///    failure is *eligible* (a `.notRepeatable` operation only when the
    ///    failure proves nothing reached the backend, `neverReachedBackend`);
    ///    an eligible failure's own ``Retryable/retryDecision`` decides; and
    ///    otherwise a `remote` or `system` backend retries and a `local` or
    ///    `compute` one stops.
    /// 3. **The breaker** (`remote` and `system`), which counts by that
    ///    classification. At `.interactive` and `.userInitiated` an open
    ///    breaker fails the call at once; at `.utility` and `.background` the
    ///    call waits it out, at most three times, spending no attempt.
    /// 4. **Admission**: the backend's capacity, partitioned by urgency; for
    ///    a write to a `local` backend, the writer lane first.
    /// 5. **The attempt's timer**: the attempt timeout of a `.brief` call to
    ///    a `remote` or `system` backend, or the deadline.
    ///
    /// ```swift
    /// enum Catalogue {
    ///     static let episode = Backend.catalogue.readOnly("episode")
    /// }
    ///
    /// let episode = try await withUrgency(.interactive) {
    ///     try await Catalogue.episode.perform { _ in try await api.episode(id) }
    /// }
    /// ```
    ///
    /// **Keys.** `attempt.idempotencyKey` is the same on every attempt: the
    /// `idempotencyKey` argument when given (make it with the intent — when
    /// the checkout opens — so a double tap and a relaunch reuse it); inside
    /// another operation's attempt, a key derived from that operation's key
    /// and this operation's names and occurrence there, the same on every
    /// enclosing attempt; otherwise one drawn when first read. A `.keyed`
    /// operation must send it: one whose key Stoic made and no attempt read
    /// is not repeated, and `operation.key_unread` is reported.
    ///
    /// **One layer retries.** Inside another retry's attempt, `perform`
    /// still retries by its own policy, and when it gives up it marks that
    /// attempt *settled*, so the enclosing `retry` does not repeat it. Inside
    /// an attempt of a `perform` on the same backend it makes one attempt in
    /// the enclosing call's slot: the enclosing call is that backend's retry
    /// layer.
    ///
    /// **Cancellation.** The caller's cancellation cancels the attempt in
    /// flight and awaits it, except a `.brief` `.keyed` or `.notRepeatable`
    /// attempt, which finishes, shielded, within its timeout and the
    /// deadline, so an outcome about to be known is known. No retry follows,
    /// and a backoff in progress ends at once with its budget token
    /// refunded.
    ///
    /// The operation runs on the caller's actor and may capture anything;
    /// its result need not be `Sendable`.
    ///
    /// - Parameters:
    ///   - idempotencyKey: The key every attempt sends, made with the intent.
    ///   - fileID: The call site, captured for events.
    ///   - line: The call site, captured for events.
    ///   - operation: One attempt.
    /// - Throws: ``OperationError``: why the call stopped, what is known
    ///   about the backend's side, and the last attempt's own failure.
    public nonisolated(nonsending) func perform<R, Failure: Error>(
        idempotencyKey: IdempotencyKey? = nil,
        fileID: String = #fileID,
        line: UInt = #line,
        operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> R
    ) async throws(OperationError<Failure>) -> R {
        let ambient = Ambient.current
        let wanted = Urgency.current
        let urgency = min(wanted, ceiling)
        if urgency < wanted {
            Ambient.record(level: .debug) {
                Event("operation.urgency_capped", level: .debug, label: cache.label, fields: [
                    .init("operation", .string(cache.label), privacy: .public),
                    .init("urgency", .string(wanted.description), privacy: .public),
                    .init("ceiling", .string(ceiling.description), privacy: .public),
                ], fileID: fileID, line: line)
            }
        }
        let state = cache.enter(backend, ambient: ambient)
        defer { state.leave() }

        // The enclosing attempt, if one is live: its key is this call's
        // parent, and it is what this call settles when it gives up.
        let enclosing = RetryContext.active.flatMap { $0.isLive ? $0 : nil }
        // An attempt of a `perform` on this same backend: that call is the
        // backend's retry layer, and this one runs in its slot.
        let outer = enclosing?.frame.flatMap { $0.isLive && $0.state === state ? $0 : nil }
        let identity: OperationIdentity
        var ambiguous = false
        if let idempotencyKey {
            identity = OperationIdentity(key: idempotencyKey, fileID: fileID, line: line)
        } else if let enclosing {
            identity = .performing(backend: backend.name, operation: name, in: enclosing, fileID: fileID, line: line)
            // A child task of the attempt runs in no deterministic order, so
            // its occurrence, and with it the key, is not reproducible.
            ambiguous = !enclosing.isCurrentTask
        } else {
            identity = OperationIdentity(fileID: fileID, line: line)
        }
        if ambiguous, safety == .keyed {
            ambient.instrumentation.record(Event("operation.key_ambiguous", level: .error, label: cache.label, fields: [
                .init("operation", .string(cache.label), privacy: .public),
            ], fileID: fileID, line: line))
        }

        let call = PerformCall(
            declaration: self, policy: cache.policies[urgency.rank], state: state, ambient: ambient,
            identity: identity, enclosing: enclosing, outer: outer, ambiguous: ambiguous,
            entryDeadline: Deadline.current, fileID: fileID, line: line
        )
        if call.entryDeadline != nil {
            return try await call.run(operation)
        }
        // No deadline from the caller: the kind's and urgency's default, which
        // every wait below honours and each attempt's timer enforces.
        let deadline = Deadline.after(call.policy.deadline, clock: ambient.clock)
        return try await Deadline.$stored.withValueTyped(deadline) { () async throws(OperationError<Failure>) -> R in
            try await call.run(operation)
        }
    }
}

extension OperationCache {
    /// The state of `backend` in `ambient`'s registry, entered: the caller
    /// leaves it when its call ends. A declaration remembers the process
    /// registry's state, so a call in production takes no registry lock.
    func enter(_ backend: Backend, ambient: Ambient) -> BackendState {
        let registry = ambient.backends
        if let cached = state.load(), cached.registry == registry.id, cached.enter() {
            return cached
        }
        let entered = registry.enter(backend, ambient: ambient)
        if registry === BackendRegistry.shared, state.load()?.isEvicted ?? true {
            _ = state.storeIfNil(entered)
        }
        return entered
    }
}

/// A `perform`'s attempt, as the attempts and operations inside it see it.
struct PerformFrame: Sendable {
    /// The backend whose slot the attempt holds.
    let state: BackendState
    /// The `perform`, and its attempt.
    let operation: OperationIdentity
    let attempt: Int
    /// Whether the attempt holds the backend's writer lane.
    let writes: Bool

    /// Whether the attempt is still running.
    var isLive: Bool {
        operation.isLive(attempt: attempt)
    }
}

/// Whether the current task runs inside a live attempt of a `perform`.
///
/// What a layer of this package that retries for itself asks before it does
/// (StoicHTTP's client): inside a declared operation's attempt it makes one
/// attempt and says what it saw, because the operation is that backend's
/// retry layer (design/22, Inside StoicHTTP). A task an attempt left running
/// finds its context stale and is not inside it.
package enum PerformAttempt {
    package static var isLive: Bool {
        guard let context = RetryContext.active, context.isLive, let frame = context.frame else { return false }
        return frame.isLive
    }
}

/// One call of `perform`: what it found on entry, and its loop.
private struct PerformCall {
    let declaration: Backend.Operation
    let policy: OperationPolicy
    let state: BackendState
    let ambient: Ambient
    let identity: OperationIdentity
    let enclosing: RetryContext?
    let outer: PerformFrame?
    let ambiguous: Bool
    /// The deadline in force on entry, the caller's (or an enclosing
    /// attempt's): `nil` when `perform` applied its default.
    let entryDeadline: Deadline?
    let fileID: String
    let line: UInt

    var label: String { declaration.cache.label }
    var rank: Int { policy.urgency.rank }

    /// How an attempt was cut off, if it was.
    enum Cut {
        /// Its own attempt timeout fired: a transient failure.
        case ownTimeout
        /// The call's deadline fired.
        case deadline
        /// The caller was cancelled.
        case caller
    }

    /// How the call ended, before it becomes an ``OperationError``.
    enum Ending: Error {
        case failed
        case rejected(Rejection)
        case cancelled
    }

    /// What the call has learnt so far.
    struct Record<Failure: Error> {
        var attempts = 0
        var last: Failure?
        /// The outcome of the last attempt that reached the backend.
        var reached: OperationError<Failure>.Outcome?
        /// Whether an enclosing deadline or attempt timeout cut the call off.
        var cutByEnclosing = false
    }

    nonisolated(nonsending) func run<R, Failure: Error>(
        _ operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> R
    ) async throws(OperationError<Failure>) -> R {
        let clock = ambient.clock
        let schedule = outer == nil ? policy.schedule : Schedule.immediate.attempts(1)
        var pacer = RetryPacer(
            ambient: ambient, clock: clock, schedule: schedule, storage: state.budget,
            label: label, fileID: fileID, line: line
        )
        var record = Record<Failure>()
        if outer == nil { state.budget.deposit() }
        var number = 1

        while true {
            // Refused before it starts: cancelled, or out of time.
            if Task.isCancelled {
                throw finish(.cancelled, record)
            }
            if let deadline = Deadline.current, deadline.hasPassed {
                record.cutByEnclosing = entryDeadline != nil
                throw finish(.rejected(Rejection(.deadlineExceeded, label: label)), record)
            }

            // The breaker: a dead backend is refused before it takes a slot.
            var ticket: CircuitBreaker.Ticket?
            if outer == nil, let breaker = state.breaker {
                switch await admit(through: breaker) {
                case .success(let admitted): ticket = admitted
                case .failure(let ending): throw finish(ending, record)
                }
            }

            // Admission: the writer lane, then the urgency's partition.
            let admission = await admit()
            guard case .success(let held) = admission else {
                if let ticket, let breaker = state.breaker {
                    breaker.complete(ticket, verdict: .ignored("rejection"), random: ambient.random, instrumentation: ambient.instrumentation)
                }
                guard case .failure(let ending) = admission else { preconditionFailure("admission neither held nor refused") }
                // A wait for a slot that the caller's deadline ended was cut
                // off by it; this call gave up on nothing.
                if case .rejected(let refusal) = ending, refusal.reason == .deadlineExceeded, entryDeadline != nil {
                    record.cutByEnclosing = true
                }
                throw finish(ending, record)
            }

            // The attempt, under its timer.
            let attemptStart = clock.now
            let attempt = Attempt(number: number, elapsed: pacer.start.duration(to: attemptStart), operation: identity)
            let frame = PerformFrame(state: state, operation: identity, attempt: number, writes: held.writes)
            let (result, cut) = await identity.running(attempt: number, frame: frame) {
                await runAttempt(attempt, operation)
            }
            release(held)
            record.attempts = number

            let failure: Failure
            switch result {
            case .success(let value):
                if let ticket, let breaker = state.breaker {
                    breaker.complete(ticket, verdict: .recorded(failed: false), random: ambient.random, instrumentation: ambient.instrumentation)
                }
                if number > 1 {
                    pacer.report("retry.succeeded", [.init("attempts", .int(number)), .init("elapsed", .duration(pacer.start.duration(to: clock.now)))])
                }
                reportUnreadKey()
                return value
            case .failure(let error):
                failure = error
            }
            record.last = failure

            let callerGone = Task.isCancelled
            let enclosingCut = callerGone && CancellationCause.current == .deadline
                || cut == .deadline && entryDeadline != nil
            let nothingReached = Self.provesNothingReached(failure)
            if !nothingReached {
                record.reached = Self.outcome(of: failure, cut: cut, kind: declaration.backend.kind)
            }
            if let ticket, let breaker = state.breaker {
                breaker.complete(
                    ticket, verdict: Self.verdict(for: failure, cut: cut, nothingReached: nothingReached, kind: declaration.backend.kind),
                    random: ambient.random, instrumentation: ambient.instrumentation
                )
            }

            let common: [Event.Field] = [.init("attempt", .int(number)), .init("error", .error(failure))]
            // 0. Something inside the attempt gave up on it.
            if identity.isSettled(attempt: number) {
                pacer.report("retry.stopped", common + [.init("reason", .string("inner_settled"), privacy: .public)])
                throw finish(.failed, record)
            }
            // 1. A defect.
            if containsDefect(failure) {
                pacer.report("retry.defect", common, level: .error)
                throw finish(.failed, record)
            }
            // 2. The caller's cancellation, or a deadline that is the call's.
            if callerGone || cut == .caller {
                if enclosingCut {
                    record.cutByEnclosing = true
                    throw finish(.rejected(Rejection(.deadlineExceeded, label: label)), record)
                }
                pacer.report("retry.cancelled", common, level: .debug)
                throw finish(.cancelled, record)
            }
            if cut == .deadline {
                record.cutByEnclosing = enclosingCut
                throw finish(.rejected(Rejection(.deadlineExceeded, label: label)), record)
            }
            // 3. Repeat safety.
            if !isEligible(nothingReached: nothingReached) {
                pacer.report("retry.permanent", common + [.init("reason", .string("not_repeatable"), privacy: .public)])
                throw finish(.failed, record)
            }
            // 4–5. The failure's own decision, else the kind's.
            let decision = cut == .ownTimeout ? .retry : Self.decision(for: failure, kind: declaration.backend.kind)
            if decision == .stop {
                pacer.report("retry.permanent", common)
                throw finish(.failed, record)
            }
            // Inside a call on the same backend: that call retries.
            if outer != nil {
                pacer.report("retry.nested", common, level: .notice)
                throw finish(.failed, record)
            }
            switch pacer.pace(
                attempt: number, decision: decision, error: failure, common: common,
                attemptDuration: attemptStart.duration(to: clock.now), timedOut: cut == .ownTimeout,
                stretches: policy.stretchesForDevice, sparesReserve: policy.urgency <= .utility
            ) {
            case .stop(.deadline(let needed)):
                throw finish(.rejected(Rejection(.deadlineExceeded, label: label, retryAfter: needed)), record)
            case .stop(.budgetExhausted):
                throw finish(.rejected(Rejection(.budgetExhausted, label: label)), record)
            case .stop:
                throw finish(.failed, record)
            case .wait(let delay, let token):
                guard await pacer.backoff(delay, token: token, common: common) else {
                    throw finish(.cancelled, record)
                }
            }
            number += 1
        }
    }

    // MARK: The breaker

    /// Through the breaker, waiting out an open one where nobody waits
    /// (design/22, Breaker): at most three waits per call, never past the
    /// deadline, consuming neither an attempt nor a budget token.
    nonisolated(nonsending) func admit(through breaker: CircuitBreaker) async -> Result<CircuitBreaker.Ticket, Ending> {
        var waits = 0
        while true {
            let rejection: Rejection
            switch breaker.admitCall(random: ambient.random, instrumentation: ambient.instrumentation) {
            case .success(let ticket): return .success(ticket)
            case .failure(let refused): rejection = refused
            }
            guard policy.waitsForOpenBreaker, waits < 3 else {
                return .failure(.rejected(Rejection(.circuitOpen, label: label, retryAfter: rejection.retryAfter)))
            }
            waits += 1
            let remaining = Deadline.current?.remaining ?? .maximum
            let clock = ambient.clock
            if let retryAfter = rejection.retryAfter {
                // Every caller was told the same instant: spread them out.
                let wait = RetryPacer.jitteredUpward(
                    retryAfter, random: ambient.random, discriminator: UInt64(waits), fileID: fileID, line: line
                )
                guard wait < remaining else {
                    return .failure(.rejected(Rejection(.circuitOpen, label: label, retryAfter: retryAfter)))
                }
                do {
                    try await clock.sleep(until: clock.now.advanced(by: wait), tolerance: nil)
                } catch {
                    return .failure(.cancelled)
                }
            } else {
                // Half-open with its probe out: wait for the probe's verdict.
                let bound = min(breaker.halfOpenTimeout, remaining)
                guard bound > .zero else {
                    return .failure(.rejected(Rejection(.circuitOpen, label: label)))
                }
                await Self.waitForVerdict(of: breaker, clock: clock, bound: bound)
            }
            if Task.isCancelled { return .failure(.cancelled) }
        }
    }

    /// Returns when `breaker` leaves the state it refused in (half-open with
    /// its probe out, or forced open), or after `bound`.
    static func waitForVerdict(of breaker: CircuitBreaker, clock: AnyClock, bound: Duration) async {
        let changes = breaker.stateChanges
        let refusing = breaker.state
        guard refusing != .closed else { return }
        let until = clock.now.advanced(by: bound)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in changes where state != refusing { return }
            }
            group.addTask {
                do { try await clock.sleep(until: until, tolerance: nil) } catch {}
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Admission

    /// What an attempt holds while it runs.
    struct Held {
        /// The partition's slot, held by this call (not borrowed).
        var slot = false
        /// A slot borrowed from the enclosing call on the same backend.
        var borrowed = false
        /// The writer lane, held by this call.
        var lane = false
        /// Whether the attempt writes under the lane, its own or the
        /// enclosing call's.
        var writes = false
    }

    nonisolated(nonsending) func admit() async -> Result<Held, Ending> {
        var held = Held()
        let writer = policy.writers != nil
        if let outer {
            held.writes = writer || outer.writes
            if writer, !outer.writes, let lane = state.lane {
                // A write under an outer read takes the lane.
                if let refusal = await lane.acquire(rank: rank) { return .failure(ending(for: refusal)) }
                held.lane = true
            }
            if outer.operation.borrowSlot(attempt: outer.attempt) {
                held.borrowed = true
                return .success(held)
            }
            // Another nested call has the enclosing slot: take one of its own.
            Ambient.record(level: .debug) {
                Event("operation.nested_admission", level: .debug, label: label, fields: [
                    .init("operation", .string(label), privacy: .public),
                ], fileID: fileID, line: line)
            }
        } else if writer, let lane = state.lane {
            // The lane before the slot, so writers waiting for the lane hold
            // no slot that reads need.
            if let refusal = await lane.acquire(rank: rank) { return .failure(ending(for: refusal)) }
            held.lane = true
            held.writes = true
        }
        if let refusal = await state.slots.acquire(rank: rank) {
            release(held)
            return .failure(ending(for: refusal))
        }
        held.slot = true
        return .success(held)
    }

    func release(_ held: Held) {
        if held.slot { state.slots.release(rank: rank) }
        if held.borrowed, let outer { outer.operation.returnSlot(attempt: outer.attempt) }
        if held.lane { state.lane?.release(rank: rank) }
    }

    func ending(for refusal: Rejection) -> Ending {
        if refusal.reason == .cancelled { return .cancelled }
        if refusal.reason == .bulkheadFull {
            ambient.instrumentation.record(Event("bulkhead.rejected", level: .info, label: label, fields: [
                .init("reason", .string(refusal.reason.rawValue), privacy: .public),
                .init("capacity", .int(declaration.backend.capacity)),
                .init("urgency", .string(policy.urgency.description), privacy: .public),
            ], fileID: fileID, line: line))
        }
        return .rejected(Rejection(refusal.reason, label: label))
    }

    // MARK: The attempt

    /// Runs one attempt: inline when the caller's deadline already bounds it
    /// and nothing needs a timer of its own, else under a timer at the
    /// earlier of its attempt timeout and the deadline, in a child task on
    /// the caller's actor.
    nonisolated(nonsending) func runAttempt<R, Failure: Error>(
        _ attempt: Attempt,
        _ operation: nonisolated(nonsending) (Attempt) async throws(Failure) -> R
    ) async -> (Result<R, Failure>, Cut?) {
        let deadline = Deadline.current
        // A brief keyed or non-repeatable attempt finishes even if its caller
        // goes, so an outcome about to be known is known.
        let shielded = declaration.length == .brief && (declaration.safety == .keyed || declaration.safety == .notRepeatable)
        let timeout = policy.attemptTimeout.map { Deadline.after($0, clock: ambient.clock) }
        let ownTimeoutFirst = timeout.map { timeout in deadline.map { timeout.isEarlier(than: $0) } ?? true } ?? false
        let timer: Deadline? = if ownTimeoutFirst { timeout } else if timeout != nil || entryDeadline == nil || shielded { deadline } else { nil }

        guard let timer else {
            let result: Result<R, Failure>
            do throws(Failure) {
                result = .success(try await operation(attempt))
            } catch {
                result = .failure(error)
            }
            return (result, Task.isCancelled ? (CancellationCause.current == .deadline ? .deadline : .caller) : nil)
        }
        let (result, expired) = await runAttemptHandingOff(
            under: timer, enforced: true, reportsExpiry: entryDeadline == nil, shielded: shielded,
            label: "\(label) attempt \(attempt.number)", fileID: fileID, line: line
        ) { () async throws(Failure) -> R in
            try await operation(attempt)
        }
        if expired { return (result, ownTimeoutFirst ? .ownTimeout : .deadline) }
        if !shielded, Task.isCancelled {
            return (result, CancellationCause.current == .deadline ? .deadline : .caller)
        }
        return (result, nil)
    }

    // MARK: Classification

    /// Step 3: whether repeat safety lets the failure be tried again.
    func isEligible(nothingReached: Bool) -> Bool {
        switch declaration.safety {
        case .readOnly, .idempotent:
            return true
        case .notRepeatable:
            return nothingReached
        case .keyed:
            // A key Stoic made that no attempt sent, or that is not
            // reproducible, makes the operation not repeatable.
            if !identity.keyWasGiven, !identity.keyWasRead || ambiguous { return nothingReached }
            return true
        }
    }

    /// Steps 4 and 5: the failure's own decision, else the kind's.
    static func decision(for failure: any Error, kind: Backend.Kind) -> RetryDecision {
        if containsCancellation(failure) { return .stop }
        if let decision = standardDecision(for: failure) { return decision }
        switch kind {
        case .remote, .system: return .retry
        case .local, .compute: return .stop
        }
    }

    /// Whether `failure` proves nothing reached the backend.
    static func provesNothingReached(_ failure: any Error) -> Bool {
        if let retryable = retryableView(of: failure), retryable.neverReachedBackend { return true }
        if let retryable = retryableView(of: failure.unwrappedForClassification) { return retryable.neverReachedBackend }
        return false
    }

    /// What a failed attempt that reached the backend says about its side.
    static func outcome<Failure: Error>(of failure: Failure, cut: Cut?, kind: Backend.Kind) -> OperationError<Failure>.Outcome {
        if cut != nil || containsDefect(failure) || containsCancellation(failure) { return .unknown }
        return decision(for: failure, kind: kind) == .stop ? .executed : .unknown
    }

    /// What the backend's breaker records for a failed attempt: a failure
    /// the classifier would retry counts against the backend; a permanent
    /// one is the backend answering; one that never reached it, a cut by
    /// the call's deadline and the caller's cancellation say nothing.
    static func verdict(for failure: any Error, cut: Cut?, nothingReached: Bool, kind: Backend.Kind) -> CircuitBreaker.Verdict {
        if containsDefect(failure) { return .ignored("defect") }
        if nothingReached { return .ignored("not_reached") }
        switch cut {
        case .ownTimeout: return .recorded(failed: true, timedOut: true)
        case .deadline: return .ignored("deadline")
        case .caller: return .ignored("cancelled")
        case nil: break
        }
        if containsCancellation(failure) { return .ignored("cancelled") }
        if failure.unwrappedForClassification is Rejection { return .ignored("rejection") }
        return .recorded(failed: decision(for: failure, kind: kind) != .stop)
    }

    // MARK: Ending

    /// The error for how the call ended, after settling the enclosing
    /// attempt and reporting what needs reporting.
    func finish<Failure: Error>(_ ending: Ending, _ record: Record<Failure>) -> OperationError<Failure> {
        var ending = ending
        var record = record
        if case .cancelled = ending, Task.isCancelled, CancellationCause.current == .deadline {
            // Cancelled by an enclosing deadline (an attempt timeout around
            // this call, the caller's `withDeadline`): it ran out of time; it
            // was not abandoned. `perform`'s own default never cancels the
            // caller's task, so the deadline is not this call's.
            ending = .rejected(Rejection(.deadlineExceeded, label: label))
            record.cutByEnclosing = true
        }
        let outcome = record.reached ?? .notExecuted
        let stop: OperationError<Failure>.Stop
        switch ending {
        case .failed:
            guard let last = record.last else { preconditionFailure("perform stopped on a failure it does not have") }
            stop = .failed(last)
        case .rejected(let rejection): stop = .rejected(rejection)
        case .cancelled: stop = .cancelled
        }
        let safety = declaration.safety
        let madeKey = !identity.keyWasGiven
        let error = OperationError(
            stop: stop, outcome: outcome, last: record.last, attempts: record.attempts, safety: safety,
            idempotencyKey: safety == .keyed ? identity.sentKey : nil, defersToEnclosing: outer != nil
        )

        // Settle the enclosing attempt, so whoever runs it does not repeat
        // what this call already retried, refused or gave up on.
        if let enclosing {
            let unsafeUnknown = outcome == .unknown && (safety == .notRepeatable || safety == .keyed && madeKey)
            let settles: Bool
            if outer != nil {
                // One attempt inside the backend's retry layer: it settles only
                // what its own safety would have stopped.
                settles = safety == .notRepeatable && outcome != .notExecuted || safety == .keyed && madeKey && outcome == .unknown
            } else {
                let cancelled: Bool
                if case .cancelled = ending { cancelled = true } else { cancelled = false }
                settles = unsafeUnknown || !(cancelled || record.cutByEnclosing)
            }
            if settles { enclosing.operation.settle(attempt: enclosing.attempt) }
        }

        if error.mayHaveActedUnsafely {
            let why = switch ending {
            case .failed: "failed"
            case .rejected(let rejection): rejection.reason.rawValue
            case .cancelled: "cancelled"
            }
            ambient.instrumentation.record(Event("operation.outcome_unknown", level: .warning, label: label, fields: [
                .init("operation", .string(label), privacy: .public),
                .init("attempts", .int(record.attempts)),
                .init("stop", .string(why), privacy: .public),
            ], fileID: fileID, line: line))
        }
        reportUnreadKey()
        return error
    }

    /// A keyed operation whose key Stoic made and no attempt read sent no
    /// key: a bug, and repeating it would be the double charge.
    func reportUnreadKey() {
        guard declaration.safety == .keyed, !identity.keyWasRead else { return }
        ambient.instrumentation.record(Event("operation.key_unread", level: .error, label: label, fields: [
            .init("operation", .string(label), privacy: .public),
        ], fileID: fileID, line: line))
    }
}
