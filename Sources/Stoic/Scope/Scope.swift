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
    ///   - acquire: Produces the resource.
    ///   - release: Releases it. Receives how the scope ended.
    public func acquire<R: Sendable, Failure: Error>(
        label: String = #function,
        shielded: Bool = false,
        timeout: Duration? = nil,
        _ acquire: nonisolated(nonsending) () async throws(Failure) -> R,
        release: @escaping @Sendable (R, Exit) async throws -> Void
    ) async throws(Failure) -> R {
        let value: R
        if shielded {
            value = try await withTaskCancellationShield { () async throws(Failure) -> R in try await acquire() }
        } else {
            value = try await acquire()
        }
        state.register(Finalizer(label: label, timeout: timeout, runsOn: .always) { exit in try await release(value, exit) })
        return value
    }

    /// Acquires a ``Resource``.
    public func acquire<R: Sendable, Failure: Error>(_ resource: Resource<R, Failure>) async throws(Failure) -> R {
        try await acquire(label: resource.label, shielded: resource.shielded, timeout: resource.timeout,
                          { () async throws(Failure) -> R in try await resource.acquire() }, release: resource.release)
    }

    /// Registers a finalizer for something already acquired.
    public func onExit(
        label: String = #function,
        timeout: Duration? = nil,
        _ finalizer: @escaping @Sendable (Exit) async throws -> Void
    ) {
        state.register(Finalizer(label: label, timeout: timeout, runsOn: .always, run: finalizer))
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
    let acquire: @Sendable () async throws(Failure) -> Value
    let release: @Sendable (Value, Exit) async throws -> Void

    public init(
        label: String,
        shielded: Bool = false,
        timeout: Duration? = nil,
        acquire: @escaping @Sendable () async throws(Failure) -> Value,
        release: @escaping @Sendable (Value, Exit) async throws -> Void
    ) {
        self.label = label
        self.shielded = shielded
        self.timeout = timeout
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
///   `timeout`), and all of them together `exitBudget`; every finalizer is
///   still given at least a quarter of a second, because cleanup that never
///   runs is worse than cleanup that runs late. A finalizer that overruns is
///   abandoned — it keeps running, unwatched — and reported
///   (`scope.finalizer_abandoned`), and the next one runs.
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
    let result: Result<R, Failure>
    do throws(Failure) {
        result = .success(try await body(scope))
    } catch {
        result = .failure(error)
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
    let run: @Sendable (Exit) async throws -> Void
}

/// The shared state behind a scope: its finalizers, and how to run them.
final class ScopeState: Sendable {
    let label: String?
    let exitBudget: Duration
    let finalizerTimeout: Duration

    private struct State {
        var finalizers: [Finalizer] = []
        var exited = false
    }

    private let state = Mutex(State())

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
        // did not await). Run the finalizer at once rather than leak.
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
                let remaining = exitBudget.saturatingSubtracting(start.duration(to: clock.now))
                let allowed = max(.milliseconds(250), min(finalizer.timeout ?? finalizerTimeout, remaining))
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
        // abandoned without holding every later release hostage.
        let task = Task<(any Error)?, Never> {
            do {
                try await finalizer.run(exit)
                return nil
            } catch {
                return error
            }
        }
        let start = clock.now
        switch await waitForTask(task, within: allowed, clock: clock) {
        case .finished(let error?):
            report("scope.finalizer_failed", .error, [.init("error", .error(error))])
        case .finished(nil):
            let took = start.duration(to: clock.now)
            if took > allowed.saturatingMultiplied(by: 0.5) {
                report("scope.finalizer_slow", .notice, [.init("took", .duration(took)), .init("allowed", .duration(allowed))])
            }
        case .timedOut:
            task.cancel()
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
