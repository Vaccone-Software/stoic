internal import Synchronization

/// A scope that also owns child tasks.
///
/// Work forked into a task scope lives exactly as long as the scope: a
/// heartbeat, a pump, an observer. When the body ends, every fork is
/// cancelled (``CancellationCause/scopeEnded``) and awaited, and only then do
/// the scope's finalizers run, so nothing still running can use a resource
/// that has been released.
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

    /// Acquires a resource, released after every fork has stopped. See ``Scope/acquire(label:shielded:timeout:_:release:)``.
    public func acquire<R: Sendable, Failure: Error>(
        label: String = #function,
        shielded: Bool = false,
        timeout: Duration? = nil,
        _ acquire: nonisolated(nonsending) () async throws(Failure) -> R,
        release: @escaping @Sendable (R, Exit) async throws -> Void
    ) async throws(Failure) -> R {
        try await Scope(state: resources).acquire(label: label, shielded: shielded, timeout: timeout, acquire, release: release)
    }

    /// Acquires a ``Resource``, released after every fork has stopped.
    public func acquire<R: Sendable, Failure: Error>(_ resource: Resource<R, Failure>) async throws(Failure) -> R {
        try await Scope(state: resources).acquire(resource)
    }

    /// Registers a finalizer, run after every fork has stopped.
    public func onExit(label: String = #function, timeout: Duration? = nil, _ finalizer: @escaping @Sendable (Exit) async throws -> Void) {
        Scope(state: resources).onExit(label: label, timeout: timeout, finalizer)
    }
}

/// Runs `body` with a ``TaskScope``. See ``TaskScope``.
public nonisolated(nonsending) func withTaskScope<R: Sendable>(
    exitBudget: Duration = .seconds(10),
    finalizerTimeout: Duration = .seconds(5),
    label: String? = nil,
    @_inheritActorContext _ body: sending @escaping @isolated(any) (borrowing TaskScope) async throws -> R
) async throws -> R {
    let resources = ScopeState(label: label, exitBudget: exitBudget, finalizerTimeout: finalizerTimeout)
    let tasks = TaskScopeState(label: label)
    let bodyTask = TaskLedger.task(.scopeBody, label: label) { () async -> Result<R, any Error> in
        do {
            return .success(try await CancellationCauseBox.$current.withValue(tasks.cause) {
                let scope = TaskScope(resources: resources, tasks: tasks)
                return try await body(scope)
            })
        } catch {
            return .failure(error)
        }
    }
    tasks.setBody(bodyTask)

    let bodyResult = await withTaskCancellationHandler {
        await bodyTask.value
    } onCancel: {
        tasks.cause.record(.userRequested)
        bodyTask.cancel()
        tasks.cancelForks(cause: .userRequested)
    }

    // The body has ended: no new forks; stop and await the running ones.
    await tasks.close()
    let forkFailures = tasks.failures

    let exit: Exit
    if !forkFailures.isEmpty {
        exit = .failure(ConcurrentFailure(forkFailures))
    } else {
        exit = bodyResult.exit
    }
    await resources.exit(exit)

    if !forkFailures.isEmpty {
        var all = forkFailures
        if case .failure(let error) = bodyResult, !(error is CancellationError) {
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
        var nextID: UInt64 = 0
        var failures: [any Error] = []
        var closed = false
    }

    private let state = Mutex(State())

    init(label: String?) {
        self.label = label
    }

    var failures: [any Error] {
        state.withLock { $0.failures }
    }

    func setBody<R>(_ task: Task<R, Never>) {
        state.withLock { $0.bodyCancel = { task.cancel() } }
    }

    func fork(label: String, _ work: @escaping @Sendable () async throws -> Void) {
        let forkCause = CancellationCauseBox(parent: cause)
        let task = TaskLedger.task(.fork, label: label) {
            do {
                try await CancellationCauseBox.$current.withValue(forkCause) {
                    try await work()
                }
            } catch {
                self.failed(error, label: label)
            }
        }
        let accepted = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.forks[state.nextID] = task
            state.nextID += 1
            return true
        }
        if !accepted {
            // Forked after the body ended (from work the body left behind):
            // a scope never adopts work it cannot wait for.
            task.cancel()
            Ambient.record(Event("scope.fork_after_exit", level: .error, label: self.label, fields: [
                .init("fork", .string(label), privacy: .public),
            ]))
        }
    }

    private func failed(_ error: any Error, label: String) {
        // A fork cancelled by the scope itself is not a failure.
        let scopeCancelled = cause.cause != nil
        if error is CancellationError, scopeCancelled { return }
        let bodyCancel = state.withLock { state -> (@Sendable () -> Void)? in
            state.failures.append(error)
            return state.failures.count == 1 ? state.bodyCancel : nil
        }
        Ambient.record(Event("scope.child_failed", level: .error, label: self.label, fields: [
            .init("fork", .string(label), privacy: .public),
            .init("error", .error(error)),
        ]))
        if let bodyCancel {
            cause.record(.siblingFailed)
            bodyCancel()
            cancelForks(cause: .siblingFailed)
        }
    }

    func cancelForks(cause reason: CancellationCause) {
        cause.record(reason)
        let forks = state.withLock { $0.forks.valuesInKeyOrder }
        for fork in forks { fork.cancel() }
    }

    /// Refuses new forks, cancels the running ones, and waits for them.
    func close() async {
        let forks = state.withLock { state -> [Task<Void, Never>] in
            state.closed = true
            return state.forks.valuesInKeyOrder
        }
        if !forks.isEmpty {
            cause.record(.scopeEnded)
            for fork in forks { fork.cancel() }
        }
        for fork in forks { await fork.value }
    }
}
