internal import Synchronization

/// How a scope ended, as its finalizers see it.
public enum Exit: Sendable, CustomStringConvertible {
    /// The body returned.
    case success
    /// The body threw.
    case failure(any Error)
    /// The body was cancelled.
    case cancelled

    /// Whether the scope ended without its body completing.
    public var isFailure: Bool {
        if case .success = self { return false }
        return true
    }

    public var description: String {
        switch self {
        case .success: "success"
        case .failure(let error): "failure(\(error))"
        case .cancelled: "cancelled"
        }
    }
}

/// What a scope does with a release when work started inside it was
/// abandoned (``abandoningAfter(_:label:limit:clock:qos:fileID:line:operation:)``).
///
/// Abandoned work may still be using what the scope is about to release: a
/// wedged call into an audio or accessibility framework still holding the
/// handle a finalizer would close. Closing it under that call is a
/// use-after-free in someone else's code.
public enum IfWorkAbandoned: Sendable, Hashable {
    /// Release as usual.
    case release
    /// Do not release: leak the resource deliberately, and report it
    /// (`scope.release_quarantined`). For handles whose release is unsafe
    /// while a call into them may still be running.
    case quarantine
}

/// Things acquired for the lifetime of a scope, released when it ends.
///
/// A `Scope` is handed to the body of ``withScope(exitBudget:finalizerTimeout:label:_:)``
/// `borrowing`, and is noncopyable: the compiler rejects any attempt to keep
/// it — to capture it in an escaping closure, store it, or return it — so
/// nothing can register a finalizer on a scope that has already ended.
public struct Scope: ~Copyable {
    let state: ScopeState

    init(state: ScopeState) {
        self.state = state
    }

    /// Acquires a resource and registers its release, in one step.
    ///
    /// The release is registered before the value reaches the body, so there
    /// is no moment in which the resource is held but would not be released.
    /// If `acquire` throws, nothing is registered.
    ///
    /// - Parameters:
    ///   - label: Names the release in events.
    ///   - shielded: Run `acquire` hidden from cancellation, so that a
    ///     cancellation arriving mid-acquire cannot leave it half done.
    ///   - timeout: How long `release` may take before it is abandoned.
    ///   - ifWorkAbandoned: Whether to release it if work started in this
    ///     scope was abandoned and may still be using it.
    ///   - acquire: Produces the resource.
    ///   - release: Releases it. Receives how the scope ended.
    public func acquire<R: Sendable, Failure: Error>(
        label: String = #function,
        shielded: Bool = false,
        timeout: Duration? = nil,
        ifWorkAbandoned: IfWorkAbandoned = .release,
        _ acquire: nonisolated(nonsending) () async throws(Failure) -> R,
        release: @escaping @Sendable (R, Exit) async throws -> Void
    ) async throws(Failure) -> R {
        let value: R
        if shielded {
            value = try await withTaskCancellationShield { () async throws(Failure) -> R in try await acquire() }
        } else {
            value = try await acquire()
        }
        var finalizer = Finalizer(label: label, timeout: timeout, runsOn: .always) { exit in try await release(value, exit) }
        finalizer.ifWorkAbandoned = ifWorkAbandoned
        state.register(finalizer)
        return value
    }

    /// Acquires a ``Resource``.
    public func acquire<R: Sendable, Failure: Error>(_ resource: Resource<R, Failure>) async throws(Failure) -> R {
        try await acquire(label: resource.label, shielded: resource.shielded, timeout: resource.timeout,
                          ifWorkAbandoned: resource.ifWorkAbandoned,
                          { () async throws(Failure) -> R in try await resource.acquire() }, release: resource.release)
    }

    /// Registers a finalizer for something already acquired.
    public func onExit(
        label: String = #function,
        timeout: Duration? = nil,
        ifWorkAbandoned: IfWorkAbandoned = .release,
        _ finalizer: @escaping @Sendable (Exit) async throws -> Void
    ) {
        var entry = Finalizer(label: label, timeout: timeout, runsOn: .always, run: finalizer)
        entry.ifWorkAbandoned = ifWorkAbandoned
        state.register(entry)
    }

    /// How many operations started inside this scope (or a scope inside it)
    /// have been abandoned so far.
    public var abandonedWork: Int {
        state.watch.count
    }
}

/// A reusable description of how to acquire and release something.
///
///     extension Database {
///         static func resource(at url: URL) -> Resource<Database, any Error> {
///             Resource(label: "database") { try await Database.open(url) }
///                 release: { database, _ in await database.close() }
///         }
///     }
public struct Resource<Value: Sendable, Failure: Error>: Sendable {
    public let label: String
    public let shielded: Bool
    public let timeout: Duration?
    public let ifWorkAbandoned: IfWorkAbandoned
    let acquire: @Sendable () async throws(Failure) -> Value
    let release: @Sendable (Value, Exit) async throws -> Void

    public init(
        label: String,
        shielded: Bool = false,
        timeout: Duration? = nil,
        ifWorkAbandoned: IfWorkAbandoned = .release,
        acquire: @escaping @Sendable () async throws(Failure) -> Value,
        release: @escaping @Sendable (Value, Exit) async throws -> Void
    ) {
        self.label = label
        self.shielded = shielded
        self.timeout = timeout
        self.ifWorkAbandoned = ifWorkAbandoned
        self.acquire = acquire
        self.release = release
    }
}

/// Runs `body` with a ``Scope``; when the body ends — by returning, throwing
/// or being cancelled — releases everything acquired in it.
///
///     try await withScope { scope in
///         let socket = try await scope.acquire { try await Socket.connect(host) }
///                                       release: { socket, _ in await socket.close() }
///         let file = try await scope.acquire(LogFile.resource(at: path))
///         try await pump(socket, into: file)
///     }
///
/// Finalizers run one at a time, in reverse order of registration, and:
///
/// - **Always run.** On success, failure and cancellation. Waiting for them
///   is hidden from cancellation, so a cancelled task still cleans up.
/// - **Are bounded.** Each may take `finalizerTimeout` (or its own
///   `timeout`), and all of them together `exitBudget`. A spent budget never
///   starves a finalizer: each is still given at least
///   `ScopeState.exitDeadlineFloor` (a quarter of a second), because cleanup
///   that never runs is worse than cleanup that runs late. The floor lifts
///   only what the budget left over; it never lengthens a timeout asked for,
///   so `timeout: .milliseconds(10)` means ten milliseconds. A finalizer that
///   overruns is abandoned — it keeps running, unwatched, but listed in
///   ``AbandonedWork/current`` until it ends — and reported
///   (`scope.finalizer_abandoned`, then `abandoned.completed` when it
///   finally finishes), and the next one runs.
/// - **Cannot change the outcome.** A finalizer that throws is reported
///   (`scope.finalizer_failed`); the body's result or error is returned
///   unchanged. Work whose failure must change the outcome — committing a
///   transaction — belongs at the end of the body, not in a finalizer.
///
/// The body's error passes through untouched.
public nonisolated(nonsending) func withScope<R, Failure: Error>(
    exitBudget: Duration = .seconds(10),
    finalizerTimeout: Duration = .seconds(5),
    label: String? = nil,
    _ body: nonisolated(nonsending) (borrowing Scope) async throws(Failure) -> R
) async throws(Failure) -> R {
    let state = ScopeState(label: label, exitBudget: exitBudget, finalizerTimeout: finalizerTimeout)
    let scope = Scope(state: state)
    // Work abandoned anywhere inside the body is counted against this scope
    // (and every scope around it), for finalizers that must not release
    // what that work may still be using.
    let result: Result<R, Failure> = await AbandonmentWatch.$current.withValue(state.watch) {
        do throws(Failure) {
            return .success(try await body(scope))
        } catch {
            return .failure(error)
        }
    }
    await state.exit(result.exit)
    return try result.get()
}

// MARK: - Finalizers and exit

struct Finalizer: Sendable {
    enum RunsOn: Sendable { case always, failureOnly }

    let label: String
    let timeout: Duration?
    let runsOn: RunsOn
    /// What is reported when the finalizer throws: a saga names its own.
    var failedEvent: EventName = "scope.finalizer_failed"
    var ifWorkAbandoned: IfWorkAbandoned = .release
    let run: @Sendable (Exit) async throws -> Void
}

/// The shared state behind a scope: its finalizers, and how to run them.
final class ScopeState: Sendable {
    /// The least a finalizer is given when the exit budget is spent.
    ///
    /// Cleanup that never runs is worse than cleanup that runs late, so an
    /// exhausted budget, or an enclosing deadline already past, still leaves
    /// each finalizer this long. It raises only the budget's share: a timeout
    /// the caller asked for, shorter than this, is honoured as written.
    static let exitDeadlineFloor: Duration = .milliseconds(250)

    let label: String?
    let exitBudget: Duration
    let finalizerTimeout: Duration

    private struct State {
        var finalizers: [Finalizer] = []
        var exited = false
    }

    private let state = Mutex(State())

    /// Counts work abandoned inside the scope.
    let watch = AbandonmentWatch(parent: AbandonmentWatch.current)

    init(label: String?, exitBudget: Duration, finalizerTimeout: Duration) {
        self.label = label
        self.exitBudget = exitBudget
        self.finalizerTimeout = finalizerTimeout
    }

    func register(_ finalizer: Finalizer) {
        let accepted = state.withLock { state -> Bool in
            guard !state.exited else { return false }
            state.finalizers.append(finalizer)
            return true
        }
        // A noncopyable, borrowed scope cannot outlive its body, so this is
        // reachable only from work the body left running (a child task it
        // did not await) that kept hold of the scope some other way. That is
        // a programming error: trap, rather than accept a finalizer that
        // would never run.
        precondition(accepted, "Scope\(label.map { " \($0)" } ?? ""): a finalizer was registered after the scope ended")
    }

    /// Runs every finalizer, newest first, shielded and bounded.
    func exit(_ exit: Exit) async {
        let finalizers = state.withLock { state -> [Finalizer] in
            state.exited = true
            return state.finalizers.reversed()
        }
        guard !finalizers.isEmpty else { return }
        let ambient = Ambient.current
        let clock = ambient.clock
        await withTaskCancellationShield {
            let start = clock.now
            for finalizer in finalizers {
                if finalizer.runsOn == .failureOnly, !exit.isFailure { continue }
                let abandoned = watch.count
                if finalizer.ifWorkAbandoned == .quarantine, abandoned > 0 {
                    ambient.instrumentation.record(Event("scope.release_quarantined", level: .warning, label: label, fields: [
                        .init("finalizer", .string(finalizer.label), privacy: .public),
                        .init("abandoned", .int(abandoned)),
                    ]))
                    continue
                }
                let remaining = exitBudget.saturatingSubtracting(start.duration(to: clock.now))
                let wanted = finalizer.timeout ?? finalizerTimeout
                let allowed = min(wanted, max(Self.exitDeadlineFloor, remaining))
                await run(finalizer, exit: exit, allowed: allowed, clock: clock, instrumentation: ambient.instrumentation)
            }
        }
    }

    private func run(
        _ finalizer: Finalizer,
        exit: Exit,
        allowed: Duration,
        clock: AnyClock,
        instrumentation: any Instrumentation
    ) async {
        let label = label
        func report(_ name: EventName, _ level: Event.Level, _ fields: [Event.Field]) {
            instrumentation.record(Event(name, level: level, label: label, fields: [.init("finalizer", .string(finalizer.label), privacy: .public)] + fields))
        }
        // Each finalizer runs in its own task, so one that hangs can be
        // abandoned without holding every later release hostage. It is
        // entered in the abandonment ledger from the start and removed when
        // it finishes, so if it is abandoned it is listed in
        // `AbandonedWork` until it does, and its late end is reported.
        let ledger = AbandonedWork.ledger
        let start = clock.now
        let ledgerLabel = "scope finalizer \(finalizer.label)"
        let id = ledger.admit(label: ledgerLabel)
        let task = Task<(any Error)?, Never>.stoic {
            // A finalizer that is slow to start exercises the slow and
            // abandoned paths.
            await FaultPoint.hit("scope.finalizer")
            let failure: (any Error)?
            do {
                try await finalizer.run(exit)
                failure = nil
            } catch {
                failure = error
            }
            if let lateness = ledger.finish(id) {
                report("abandoned.completed", .notice, [
                    .init("ran_for", .duration(start.duration(to: clock.now))),
                    .init("late_by", .duration(lateness)),
                ])
            }
            return failure
        }
        switch await waitForTask(task, within: allowed, clock: clock) {
        case .finished(let error?):
            report(finalizer.failedEvent, .error, [.init("error", .error(error))])
        case .finished(nil):
            let took = start.duration(to: clock.now)
            if took > allowed.saturatingMultiplied(by: 0.5) {
                report("scope.finalizer_slow", .notice, [.init("took", .duration(took)), .init("allowed", .duration(allowed))])
            }
        case .timedOut:
            task.cancel()
            _ = ledger.abandon(id, deadline: clock.now, clock: clock)
            report("scope.finalizer_abandoned", .error, [.init("allowed", .duration(allowed))])
        }
    }
}

extension Result {
    /// How a scope whose body produced this result ended.
    ///
    /// Only a `CancellationError` means cancelled. A body that throws a real
    /// error on a task that happens to be cancelled failed, and its
    /// finalizers and compensations should see the error, not a cancellation
    /// that hides it.
    var exit: Exit {
        switch self {
        case .success:
            return .success
        case .failure(let error):
            return error is CancellationError ? .cancelled : .failure(error)
        }
    }
}

enum TaskWait<T: Sendable>: Sendable {
    case finished(T)
    case timedOut
}

/// Waits for `task` to finish, but no longer than `limit` on `clock`.
///
/// The task is neither cancelled nor awaited past the limit: a task group
/// cannot be used, because leaving it would wait for a child stuck on a task
/// that may never finish. Instead, a watcher and a timer race to settle a
/// cell; the watcher lives exactly as long as the task it watches.
func waitForTask<T: Sendable>(_ task: Task<T, Never>, within limit: Duration, clock: AnyClock) async -> TaskWait<T> {
    let outcome = OnceCell<TaskWait<T>>()
    Task.stoic { outcome.resolve(.finished(await task.value)) }
    let timer = Task.stoic {
        do {
            try await clock.sleep(until: clock.now.advanced(by: limit), tolerance: nil)
            outcome.resolve(.timedOut)
        } catch {}
    }
    let result = await outcome.value
    timer.cancel()
    return result
}

/// Counts work abandoned inside a scope, and in every scope around it.
final class AbandonmentWatch: Sendable {
    @TaskLocal static var current: AbandonmentWatch?

    private let parent: AbandonmentWatch?
    private let abandoned = Atomic<Int>(0)

    init(parent: AbandonmentWatch?) {
        self.parent = parent
    }

    var count: Int {
        abandoned.load(ordering: .relaxed)
    }

    /// Records one abandoned operation here and in every enclosing scope:
    /// work started in an inner scope may be using an outer scope's resources.
    func record() {
        abandoned.wrappingAdd(1, ordering: .relaxed)
        parent?.record()
    }
}
