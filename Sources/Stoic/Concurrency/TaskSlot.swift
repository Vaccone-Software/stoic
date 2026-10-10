internal import Synchronization

/// Holds at most one piece of work: starting new work supersedes the old.
///
/// The structured replacement for generation counters. A search box, a
/// preview that follows a selection, a refresh triggered by every keystroke —
/// each wants only the latest request's answer. By hand, that is a counter
/// bumped on every request and compared in every callback, and one forgotten
/// comparison publishes a stale result. A slot makes the comparison itself:
///
///     @MainActor final class SearchModel {
///         private let search = TaskSlot<[Hit], any Error>(label: "search")
///         var hits: [Hit] = []
///
///         func queryChanged(_ query: String) {
///             search.run {
///                 try await api.search(query)
///             } deliver: { result in
///                 self.hits = (try? result.get()) ?? []
///             }
///         }
///     }
///
/// `deliver` is called only for the newest work, on the actor that called
/// `run`, synchronously after checking that nothing newer has started — so
/// no `run` can slip in between the check and the delivery. Superseded work
/// is cancelled with ``CancellationCause/superseded``; if it finishes anyway,
/// its result is dropped and reported (`slot.superseded_late`).
///
/// ``run(isolation:_:deliver:)`` starts the new work at once, while the old
/// may still be winding down. When the two must never overlap — both use the
/// microphone, say — use ``runExclusively(isolation:_:deliver:)``, which
/// waits for the old work to finish first.
public final class TaskSlot<Success: Sendable, Failure: Error>: Sendable {
    /// Names the slot in events.
    public let label: String

    private struct Current {
        let generation: UInt64
        let task: Task<Void, Never>
        let cause: CancellationCauseBox
    }

    private struct State {
        var generation: UInt64 = 0
        var current: Current?
        // The newest generation whose task has finished: a task can finish
        // before `start` records it as current, and must not then be
        // recorded as running.
        var finished: UInt64 = 0
    }

    private let state = Mutex(State())

    public init(label: String) {
        self.label = label
    }

    deinit {
        let current = state.withLock { $0.current }
        current?.cause.record(.scopeEnded)
        current?.task.cancel()
    }

    /// Whether work is in the slot and has not finished.
    public var isRunning: Bool {
        state.withLock { $0.current != nil }
    }

    /// Supersedes any current work and starts `operation` at once.
    ///
    /// - Parameters:
    ///   - operation: The new work. Like `Task {}`, it inherits the caller's actor.
    ///   - deliver: Receives the outcome, on the caller's actor, only if no
    ///     newer work has been started by then.
    public func run(
        isolation: isolated (any Actor)? = #isolation,
        @_inheritActorContext _ operation: sending @escaping @isolated(any) () async throws(Failure) -> Success,
        deliver: sending @escaping (Result<Success, Failure>) -> Void
    ) {
        let (generation, previous) = supersede()
        start(generation: generation, waitingFor: nil, isolation: isolation, operation: operation, deliver: deliver)
        _ = previous
    }

    /// Supersedes any current work, waits for it to finish, then starts
    /// `operation`, so the two never overlap.
    ///
    /// If yet newer work arrives while waiting, this work is superseded
    /// before it starts and never runs.
    public func runExclusively(
        isolation: isolated (any Actor)? = #isolation,
        @_inheritActorContext _ operation: sending @escaping @isolated(any) () async throws(Failure) -> Success,
        deliver: sending @escaping (Result<Success, Failure>) -> Void
    ) {
        let (generation, previous) = supersede()
        start(generation: generation, waitingFor: previous, isolation: isolation, operation: operation, deliver: deliver)
    }

    /// Cancels the current work, if any. Its result will not be delivered.
    public func cancel() {
        let current = state.withLock { state -> Current? in
            state.generation += 1
            defer { state.current = nil }
            return state.current
        }
        current?.cause.record(.superseded)
        current?.task.cancel()
    }

    /// Cancels the current work and waits for it to finish.
    public func cancelAndWait() async {
        let current = state.withLock { state -> Current? in
            state.generation += 1
            defer { state.current = nil }
            return state.current
        }
        current?.cause.record(.superseded)
        current?.task.cancel()
        await current?.task.value
    }

    // MARK: Internals

    private func supersede() -> (UInt64, Task<Void, Never>?) {
        let (generation, previous) = state.withLock { state -> (UInt64, Current?) in
            state.generation += 1
            return (state.generation, state.current)
        }
        if let previous {
            previous.cause.record(.superseded)
            previous.task.cancel()
            Ambient.record(Event("slot.superseded", level: .debug, label: label))
        }
        return (generation, previous?.task)
    }

    private func start(
        generation: UInt64,
        waitingFor previous: Task<Void, Never>?,
        isolation: isolated (any Actor)?,
        operation: sending @escaping @isolated(any) () async throws(Failure) -> Success,
        deliver: sending @escaping (Result<Success, Failure>) -> Void
    ) {
        let cause = CancellationCauseBox(parent: nil)
        let slot = OperationSlot(operation)
        let label = label
        // The task holds the slot weakly: a slot whose owner has gone away
        // cancels its work in `deinit` and delivers nothing.
        let task = Task { [weak self] in
            if let previous {
                await previous.value
                guard self?.isCurrent(generation) == true, !Task.isCancelled else {
                    self?.finish(generation)
                    return
                }
            }
            let result = await CancellationCauseBox.$current.withValue(cause) {
                await slot.runResult()
            }
            TaskSlot.complete(isolation: isolation, slot: self, generation: generation, label: label, result: result, deliver: deliver)
        }
        state.withLock { state in
            if state.generation == generation, state.finished < generation {
                state.current = Current(generation: generation, task: task, cause: cause)
            }
        }
    }

    /// Delivers on the caller's actor. The check and the delivery happen
    /// together, with no suspension in between, so no `run` can slip in.
    private static func complete(
        isolation: isolated (any Actor)?,
        slot: TaskSlot?,
        generation: UInt64,
        label: String,
        result: Result<Success, Failure>,
        deliver: sending (Result<Success, Failure>) -> Void
    ) {
        guard let slot else { return }
        if slot.isCurrent(generation) {
            deliver(result)
        } else if !Task.isCancelled || result.isSuccess {
            Ambient.record(Event("slot.superseded_late", label: label))
        }
        slot.finish(generation)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation }
    }

    private func finish(_ generation: UInt64) {
        state.withLock { state in
            state.finished = max(state.finished, generation)
            if state.current?.generation == generation {
                state.current = nil
            }
        }
    }
}
