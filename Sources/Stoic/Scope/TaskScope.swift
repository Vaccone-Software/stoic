internal import Synchronization

/// A scope that also owns child tasks.
///
/// Work forked into a task scope lives exactly as long as the scope: a
/// heartbeat, a pump, an observer. When the body ends, every fork is
/// cancelled (``CancellationCause/scopeEnded``) and awaited, and only then do
/// the scope's finalizers run, so nothing still running can use a resource
/// that has been released. A fork that finishes is forgotten at once, so a
/// scope that lives long and forks per event holds only what is running.
///
/// Waiting for forks is bounded. Cancellation is cooperative: a fork that
/// never looks at it (a blocked call, a loop without a suspension point)
/// would otherwise hold the scope, and every finalizer behind it, forever.
/// Forks get `forkTimeout` after the body ends to stop (within the exit
/// budget and the enclosing deadline, as finalizers are); any still running
/// then are *abandoned*, as an overrunning finalizer is: the scope goes on,
/// the fork keeps running unwatched but listed in ``AbandonedWork/current``
/// and ``TaskLedger/current`` until it ends, `scope.fork_abandoned` is
/// reported, and the scope's ``abandonedWork`` counts it while it runs — so
/// a release declared `ifWorkAbandoned: .quarantine` is skipped rather than
/// run under a fork that may still be using the resource.
///
/// A fork that fails cancels the body and every other fork
/// (``CancellationCause/siblingFailed``): one broken part stops the whole.
/// The scope then throws a ``ConcurrentFailure`` with every fork failure, in
/// order, followed by the body's own error if it failed for some other reason
/// than the cancellation the fork caused.
///
/// The body runs as a child task, which is what lets a failing fork cancel it
/// without cancelling the caller. Like `Task {}`, it inherits the caller's
/// actor, and its result must be `Sendable`.
public struct TaskScope: ~Copyable {
    let resources: ScopeState
    let tasks: TaskScopeState

    /// Starts `work` as a child of this scope.
    public func fork(label: String, _ work: @escaping @Sendable () async throws -> Void) {
        tasks.fork(label: label, work)
    }

    /// Acquires a resource, released after every fork has stopped. See ``Scope/acquire(label:shielded:timeout:ifWorkAbandoned:_:release:)``.
    public func acquire<R: Sendable, Failure: Error>(
        label: String = #function,
        shielded: Bool = false,
        timeout: Duration? = nil,
        ifWorkAbandoned: IfWorkAbandoned = .release,
        _ acquire: nonisolated(nonsending) () async throws(Failure) -> R,
        release: @escaping @Sendable (R, Exit) async throws -> Void
    ) async throws(Failure) -> R {
        try await Scope(state: resources).acquire(label: label, shielded: shielded, timeout: timeout, ifWorkAbandoned: ifWorkAbandoned, acquire, release: release)
    }

    /// Acquires a ``Resource``, released after every fork has stopped.
    public func acquire<R: Sendable, Failure: Error>(_ resource: Resource<R, Failure>) async throws(Failure) -> R {
        try await Scope(state: resources).acquire(resource)
    }

    /// Registers a finalizer, run after every fork has stopped.
    public func onExit(label: String = #function, timeout: Duration? = nil, ifWorkAbandoned: IfWorkAbandoned = .release, _ finalizer: @escaping @Sendable (Exit) async throws -> Void) {
        Scope(state: resources).onExit(label: label, timeout: timeout, ifWorkAbandoned: ifWorkAbandoned, finalizer)
    }

    /// How many operations, forks and finalizers started inside this scope
    /// (or a scope inside it) were abandoned and are still running.
    public var abandonedWork: Int {
        resources.watch.count
    }
}

/// Runs `body` with a ``TaskScope``. See ``TaskScope``.
///
/// - Parameters:
///   - exitBudget: How long the exit phase (waiting for forks, running
///     finalizers) may take in all. Each stage still gets the floor of a
///     quarter of a second, unless it asked for less.
///   - finalizerTimeout: How long one finalizer may take.
///   - forkTimeout: How long forks get to stop, once the body has ended and
///     cancelled them, before they are abandoned (see ``TaskScope``); within
///     `exitBudget` and the enclosing deadline.
///   - label: Names the scope in events and reports.
///   - body: The work the scope owns.
public nonisolated(nonsending) func withTaskScope<R: Sendable>(
    exitBudget: Duration = .seconds(10),
    finalizerTimeout: Duration = .seconds(5),
    forkTimeout: Duration = .seconds(5),
    label: String? = nil,
    @_inheritActorContext _ body: sending @escaping @isolated(any) (borrowing TaskScope) async throws -> R
) async throws -> R {
    let resources = ScopeState(label: label, exitBudget: exitBudget, finalizerTimeout: finalizerTimeout)
    let tasks = TaskScopeState(label: label, watch: resources.watch)
    let bodyTask = TaskLedger.task(.scopeBody, label: label) { () async -> Result<R, any Error> in
        do {
            return .success(try await AbandonmentWatch.$current.withValue(resources.watch) {
                try await CancellationCauseBox.$current.withValue(tasks.cause) {
                    let scope = TaskScope(resources: resources, tasks: tasks)
                    return try await body(scope)
                }
            })
        } catch {
            return .failure(error)
        }
    }
    tasks.setBody(bodyTask)

    let bodyResult = await withTaskCancellationHandler {
        await bodyTask.value
    } onCancel: {
        // The caller was cancelled: by an enclosing Stoic scope, which
        // recorded why before it cancelled, or by someone else.
        let cause = CancellationCauseBox.outsideCause(seenBy: tasks.cause.parent)
        tasks.cause.record(cause)
        bodyTask.cancel()
        tasks.cancelForks(cause: cause)
    }

    // The body has ended: no new forks; stop and await the running ones.
    // Waiting for forks is the first stage of the exit, charged to the same
    // budget (and bounded by the same enclosing deadline) as the finalizers
    // after it, so the whole exit has one bound.
    let clock = Ambient.current.clock
    let exitStart = clock.now
    await tasks.close(within: resources.allowance(wanting: forkTimeout, since: exitStart, clock: clock, enclosing: Deadline.current))
    let forkFailures = tasks.failures

    let exit: Exit
    if !forkFailures.isEmpty {
        exit = .failure(ConcurrentFailure(forkFailures))
    } else {
        exit = bodyResult.exit
    }
    await resources.exit(exit, startedAt: exitStart)

    if !forkFailures.isEmpty {
        var all = forkFailures
        if case .failure(let error) = bodyResult, !containsCancellation(error) {
            all.append(error)
        }
        throw ConcurrentFailure(all)
    }
    return try bodyResult.get()
}

/// The child tasks of a task scope.
final class TaskScopeState: Sendable {
    let label: String?
    let cause = CancellationCauseBox()

    private struct State {
        var body: Task<Void, Never>?
        var bodyCancel: (@Sendable () -> Void)?
        var forks: [UInt64: Task<Void, Never>] = [:]
        var forkLabels: [UInt64: String] = [:]
        var nextID: UInt64 = 0
        var failures: [any Error] = []
        var closed = false
        // A fork failed before the body task was handed over: the body is
        // cancelled the moment it arrives, or it would run on, uncancelled.
        var cancelBodyOnArrival = false
    }

    private let state = Mutex(State())

    /// Counts the forks abandoned at close, for the scope's finalizers.
    private let watch: AbandonmentWatch?

    init(label: String?, watch: AbandonmentWatch? = nil) {
        self.label = label
        self.watch = watch
    }

    var failures: [any Error] {
        state.withLock { $0.failures }
    }

    /// How many forks the scope is holding on to: those still running.
    var trackedForkCount: Int {
        state.withLock { $0.forks.count }
    }

    func setBody<R>(_ task: Task<R, Never>) {
        let cancelNow = state.withLock { state -> Bool in
            state.bodyCancel = { task.cancel() }
            return state.cancelBodyOnArrival
        }
        // A fork failed (and recorded `siblingFailed`) in the window between
        // the body task starting and this call.
        if cancelNow { task.cancel() }
    }

    func fork(label: String, _ work: @escaping @Sendable () async throws -> Void) {
        // A closed scope never starts the work: not even to cancel it at once.
        let open = state.withLock { !$0.closed }
        guard open else { rejectFork(label: label); return }
        let forkCause = CancellationCauseBox(parent: cause)
        // The task waits at this gate until it is registered, so a fork that
        // loses the race with `close()` never runs a line of its work. The
        // gate hands it its registration, `nil` if it lost.
        let registered = OnceCell<UInt64?>()
        let task = TaskLedger.task(.fork, label: label) {
            guard let id = await registered.value else { return }
            do {
                try await AbandonmentWatch.$current.withValue(self.watch) {
                    try await CancellationCauseBox.$current.withValue(forkCause) {
                        try await work()
                    }
                }
            } catch {
                self.failed(error, label: label)
            }
            // Finished, and its failure (if any) recorded: the scope has
            // nothing left to cancel or await, so it lets go of the task. A
            // long-lived scope that forks per event stays the same size.
            self.finished(id)
        }
        let id = state.withLock { state -> UInt64? in
            guard !state.closed else { return nil }
            defer { state.nextID += 1 }
            state.forks[state.nextID] = task
            state.forkLabels[state.nextID] = label
            return state.nextID
        }
        registered.resolve(id)
        if id == nil {
            task.cancel()
            rejectFork(label: label)
        }
    }

    private func finished(_ id: UInt64) {
        state.withLock { state in
            state.forks.removeValue(forKey: id)
            state.forkLabels.removeValue(forKey: id)
        }
    }

    /// Forked after the body ended (from work the body left behind): a scope
    /// never adopts work it cannot wait for.
    private func rejectFork(label: String) {
        Ambient.record(Event("scope.fork_after_exit", level: .error, label: self.label, fields: [
            .init("fork", .string(label), privacy: .public),
        ]))
    }

    private func failed(_ error: any Error, label: String) {
        // A fork cancelled by the scope itself is not a failure.
        let scopeCancelled = cause.cause != nil
        if containsCancellation(error), scopeCancelled { return }
        let (isFirst, bodyCancel) = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            state.failures.append(error)
            guard state.failures.count == 1 else { return (false, nil) }
            // The body may not exist yet; if so, `setBody` cancels it.
            if state.bodyCancel == nil { state.cancelBodyOnArrival = true }
            return (true, state.bodyCancel)
        }
        // Before the body can be cancelled (here or in `setBody`), so it
        // always sees why.
        if isFirst { cause.record(.siblingFailed) }
        Ambient.record(Event("scope.child_failed", level: .error, label: self.label, fields: [
            .init("fork", .string(label), privacy: .public),
            .init("error", .error(error)),
        ]))
        if isFirst {
            bodyCancel?()
            cancelForks(cause: .siblingFailed)
        }
    }

    func cancelForks(cause reason: CancellationCause) {
        cause.record(reason)
        let forks = state.withLock { $0.forks.valuesInKeyOrder }
        for fork in forks { fork.cancel() }
    }

    /// Refuses new forks, cancels the running ones, and waits for them — up
    /// to `limit`; any still running then are abandoned.
    /// A fork that is not in the table any more has finished its work.
    func close(within limit: Duration = .seconds(5), clock: AnyClock? = nil) async {
        let forks = state.withLock { state -> [Task<Void, Never>] in
            state.closed = true
            return state.forks.valuesInKeyOrder
        }
        guard !forks.isEmpty else { return }
        cause.record(.scopeEnded)
        for fork in forks { fork.cancel() }
        let clock = clock ?? Ambient.current.clock
        let allStopped = Task.stoic {
            for fork in forks { await fork.value }
        }
        guard case .timedOut = await waitForTask(allStopped, within: limit, clock: clock) else { return }
        abandonRunningForks(allowed: limit, clock: clock)
    }

    /// Accounts for the forks that outlived their time: listed until they
    /// end, counted against the scope, reported, and not waited for.
    private func abandonRunningForks(allowed: Duration, clock: AnyClock) {
        let running = state.withLock { state in
            state.forks.keys.sorted().compactMap { id in
                state.forks[id].map { (task: $0, label: state.forkLabels[id] ?? "") }
            }
        }
        let ledger = AbandonedWork.ledger
        for (task, forkLabel) in running {
            let start = clock.now
            let id = ledger.admit(label: "scope \(label.map { "\($0) " } ?? "")fork \(forkLabel)")
            _ = ledger.abandon(id, deadline: start, clock: clock, watch: watch)
            Ambient.record(Event("scope.fork_abandoned", level: .error, label: label, fields: [
                .init("fork", .string(forkLabel), privacy: .public),
                .init("allowed", .duration(allowed)),
            ]))
            let scopeLabel = label
            Task.stoic {
                await task.value
                if let lateness = ledger.finish(id) {
                    Ambient.record(Event("abandoned.completed", level: .notice, label: scopeLabel, fields: [
                        .init("fork", .string(forkLabel), privacy: .public),
                        .init("ran_for", .duration(start.duration(to: clock.now))),
                        .init("late_by", .duration(lateness)),
                    ]))
                }
            }
        }
    }
}
