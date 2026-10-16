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
///         private let api: SearchAPI
///         var hits: [Hit] = []
///
///         func queryChanged(_ query: String) {
///             search.run(for: self) { [api] in
///                 try await api.search(query)
///             } deliver: { @MainActor model, result in
///                 model.hits = (try? result.get()) ?? []
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
/// **The owner goes, the work goes.** The slot holds `owner` weakly and
/// hands it to `deliver`, so nothing the slot keeps holds the owner alive,
/// and `deliver` never needs to capture `self`. A slot belongs to its owner (a
/// stored property), so when the owner goes the slot goes, and a released
/// slot cancels its work; if the work finishes anyway, there is no owner to
/// deliver to and nothing is delivered. Capture what the work needs (`[api]`
/// above), not `self`: work that holds its owner keeps it, and itself, alive.
///
/// ``run(for:isolation:_:deliver:)`` starts the new work at once, while the
/// old may still be winding down. When the two must never overlap — both use
/// the microphone, say — use ``runExclusively(for:isolation:_:deliver:)``,
/// which waits for *every* earlier piece of work, superseded or cancelled, to
/// finish first.
///
/// Both must be called on an actor: the check that nothing newer has started
/// and the delivery are atomic only because that actor runs them, with any
/// `run` that could come between. The compiler refuses a call from
/// nonisolated code. `deliver` runs on that actor; to touch its state, say so
/// in the closure — `{ @MainActor model, result in … }`, as above — since
/// Swift does not infer a closure parameter's isolation from the call site.
public final class TaskSlot<Success: Sendable, Failure: Error>: Sendable {
    /// Names the slot in events.
    public let label: String

    private struct Work {
        let task: Task<Void, Never>
        let cause: CancellationCauseBox
    }

    private struct State {
        var generation: UInt64 = 0
        // Every piece of work that has not finished, current or superseded.
        // Kept until it ends, so exclusive work can wait for all of it and
        // cancellation can reach all of it.
        var unfinished: [UInt64: Work] = [:]
    }

    private let state = Mutex(State())

    public init(label: String) {
        self.label = label
    }

    deinit {
        let work = state.withLock { $0.unfinished.valuesInKeyOrder }
        for item in work {
            item.cause.record(.scopeEnded)
            item.task.cancel()
        }
    }

    /// Whether the newest work is running.
    public var isRunning: Bool {
        state.withLock { $0.unfinished[$0.generation] != nil }
    }

    /// How many pieces of work have not finished, superseded ones included.
    public var unfinishedCount: Int {
        state.withLock { $0.unfinished.count }
    }

    /// Supersedes any current work and starts `operation` at once.
    ///
    /// - Parameters:
    ///   - owner: What the result is for, usually `self`: held weakly, and
    ///     handed to `deliver`. Once it is gone nothing is delivered.
    ///   - isolation: The actor `deliver` runs on; the caller's, by default.
    ///   - operation: The new work. Like `Task {}`, it inherits the caller's actor.
    ///   - deliver: Receives the owner and the outcome, on the caller's actor,
    ///     only if no newer work has been started by then and the owner is
    ///     still there.
    public func run<Owner: AnyObject>(
        for owner: Owner,
        isolation: isolated any Actor = #isolation,
        @_inheritActorContext _ operation: sending @escaping @isolated(any) () async throws(Failure) -> Success,
        deliver: sending @escaping (Owner, Result<Success, Failure>) -> Void
    ) {
        start(exclusive: false, owner: owner, isolation: isolation, operation: operation, deliver: deliver)
    }

    /// Supersedes any current work, waits for every earlier piece of work to
    /// finish, then starts `operation`, so no two ever overlap.
    ///
    /// If yet newer work arrives while waiting, this work is superseded
    /// before it starts and never runs. The parameters are
    /// ``run(for:isolation:_:deliver:)``'s.
    public func runExclusively<Owner: AnyObject>(
        for owner: Owner,
        isolation: isolated any Actor = #isolation,
        @_inheritActorContext _ operation: sending @escaping @isolated(any) () async throws(Failure) -> Success,
        deliver: sending @escaping (Owner, Result<Success, Failure>) -> Void
    ) {
        start(exclusive: true, owner: owner, isolation: isolation, operation: operation, deliver: deliver)
    }

    /// Cancels all work in the slot. No result will be delivered.
    public func cancel() {
        let work = state.withLock { state -> [Work] in
            state.generation += 1
            return state.unfinished.valuesInKeyOrder
        }
        for item in work {
            item.cause.record(.superseded)
            item.task.cancel()
        }
    }

    /// Cancels all work in the slot and waits for every piece to finish.
    public func cancelAndWait() async {
        cancel()
        for task in state.withLock({ $0.unfinished.valuesInKeyOrder.map(\.task) }) {
            await task.value
        }
    }

    // MARK: Internals

    private func start<Owner: AnyObject>(
        exclusive: Bool,
        owner: Owner,
        isolation: isolated any Actor,
        operation: sending @escaping @isolated(any) () async throws(Failure) -> Success,
        deliver: sending @escaping (Owner, Result<Success, Failure>) -> Void
    ) {
        // Supersede: everything already in the slot is cancelled, and is
        // what exclusive work waits for.
        let (generation, superseded) = state.withLock { state -> (UInt64, [Work]) in
            state.generation += 1
            return (state.generation, state.unfinished.valuesInKeyOrder)
        }
        for item in superseded {
            item.cause.record(.superseded)
            item.task.cancel()
        }
        if !superseded.isEmpty {
            Ambient.record(level: .debug) { Event("slot.superseded", level: .debug, label: self.label) }
        }
        let earlier = superseded.map(\.task)

        let cause = CancellationCauseBox(parent: nil)
        let slot = OperationSlot(operation)
        let label = label
        // The task waits on this gate until it is registered, so work that
        // is superseded before registration never runs at all — and every
        // task that does run is registered, so nothing escapes cancellation.
        let registered = OnceCell<Bool>()
        // Neither the slot nor the owner is held by the work: a released
        // owner releases its slot, and a released slot cancels the work.
        let task = TaskLedger.task(.slot, label: label) { [weak self, weak owner] in
            guard await registered.value else { return }
            if exclusive {
                for task in earlier { await task.value }
                guard self?.isCurrent(generation) == true, !Task.isCancelled else {
                    self?.finish(generation)
                    return
                }
            }
            // The work outlives the caller's `withTimeout`, so it must not
            // inherit that deadline (it would run already expired); the same
            // reset SingleFlight, StateMachine and Supervisor make.
            let result = await Deadline.$stored.withValue(nil) {
                await CancellationCauseBox.$current.withValue(cause) {
                    await slot.runResult()
                }
            }
            // Between finishing and delivering: where newer work may arrive.
            await FaultPoint.hit("slot.deliver")
            TaskSlot.complete(isolation: isolation, slot: self, owner: owner, generation: generation, label: label,
                              result: result, deliver: deliver)
        }
        let isCurrent = state.withLock { state -> Bool in
            guard state.generation == generation else { return false }
            state.unfinished[generation] = Work(task: task, cause: cause)
            return true
        }
        if !isCurrent { task.cancel() }
        registered.resolve(isCurrent)
    }

    /// Delivers on the caller's actor. The check and the delivery happen
    /// together, with no suspension in between, so no `run` can slip in.
    private static func complete<Owner: AnyObject>(
        isolation: isolated any Actor,
        slot: TaskSlot?,
        owner: Owner?,
        generation: UInt64,
        label: String,
        result: Result<Success, Failure>,
        deliver: sending (Owner, Result<Success, Failure>) -> Void
    ) {
        guard let slot else { return }
        if slot.isCurrent(generation) {
            // An owner that has gone has nothing to deliver to.
            if let owner { deliver(owner, result) }
        } else if !Task.isCancelled || result.isSuccess {
            Ambient.record(Event("slot.superseded_late", label: label))
        }
        slot.finish(generation)
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation }
    }

    private func finish(_ generation: UInt64) {
        state.withLock { _ = $0.unfinished.removeValue(forKey: generation) }
    }
}
