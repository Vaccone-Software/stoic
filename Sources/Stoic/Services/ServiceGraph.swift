internal import Synchronization

/// Names one service in a ``ServiceGraph``, and the type it provides.
///
/// A key is a value, not a type: two databases are two keys of the same
/// type, which type-keyed dependency injection cannot express.
///
///     let database = ServiceKey<Database>("database")
///     let cache = ServiceKey<Database>("cache")
public struct ServiceKey<Value: Sendable>: Sendable, Hashable, CustomStringConvertible {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var description: String { name }

    var erased: AnyServiceKey { AnyServiceKey(name: name) }
}

/// A key without its type, for dependency lists.
public struct AnyServiceKey: Sendable, Hashable, CustomStringConvertible {
    public let name: String

    public var description: String { name }
}

extension ServiceKey {
    /// This key without its type.
    public var any: AnyServiceKey { erased }
}

/// The services a factory or a graph's body can see.
///
/// A factory sees only the services it declared it `needs`; asking for any
/// other is a programming error, caught the first time it happens, so the
/// declared graph — which decides start order — cannot quietly lie.
public struct Services: Sendable {
    private let values: [AnyServiceKey: any Sendable]
    private let visible: Set<AnyServiceKey>?
    private let owner: String?

    init(values: [AnyServiceKey: any Sendable], visible: Set<AnyServiceKey>?, owner: String?) {
        self.values = values
        self.visible = visible
        self.owner = owner
    }

    /// The service for `key`.
    public subscript<Value>(key: ServiceKey<Value>) -> Value {
        if let visible, !visible.contains(key.erased) {
            preconditionFailure("service \(owner ?? "?") used \(key) without declaring it in needs:")
        }
        guard let value = values[key.erased] as? Value else {
            preconditionFailure("service \(key) is not in the graph")
        }
        return value
    }
}

/// One service: how to start it, what it needs, and how to stop it.
public struct Provide: Sendable {
    let key: AnyServiceKey
    let needs: [AnyServiceKey]
    let startTimeout: Duration
    let stopTimeout: Duration?
    let start: @Sendable (Services) async throws -> any Sendable
    let stop: @Sendable (any Sendable, Exit) async throws -> Void

    /// - Parameters:
    ///   - key: The service's key.
    ///   - needs: The services it uses. They start before it and stop after it.
    ///   - startTimeout: How long starting may take.
    ///   - stopTimeout: How long stopping may take (the graph's default if `nil`).
    ///   - start: Creates the service from the ones it needs.
    ///   - stop: Releases it.
    public init<Value: Sendable>(
        _ key: ServiceKey<Value>,
        needs: [AnyServiceKey] = [],
        startTimeout: Duration = .seconds(30),
        stopTimeout: Duration? = nil,
        start: @escaping @Sendable (Services) async throws -> Value,
        stop: @escaping @Sendable (Value, Exit) async throws -> Void = { _, _ in }
    ) {
        self.key = key.erased
        self.needs = needs
        self.startTimeout = startTimeout
        self.stopTimeout = stopTimeout
        self.start = { services in try await start(services) }
        self.stop = { value, exit in
            guard let value = value as? Value else { return }
            try await stop(value, exit)
        }
    }
}

/// Collects a graph's services.
@resultBuilder
public enum ServicesBuilder {
    public static func buildExpression(_ service: Provide) -> [Provide] { [service] }
    public static func buildBlock(_ parts: [Provide]...) -> [Provide] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [Provide]?) -> [Provide] { part ?? [] }
    public static func buildEither(first: [Provide]) -> [Provide] { first }
    public static func buildEither(second: [Provide]) -> [Provide] { second }
    public static func buildArray(_ parts: [[Provide]]) -> [Provide] { parts.flatMap { $0 } }
}

/// Why a service graph could not be built or started.
public enum ServiceGraphError: Error, CustomStringConvertible {
    /// Two services share a key.
    case duplicate(AnyServiceKey)
    /// A service needs one that is not in the graph.
    case missing(service: AnyServiceKey, needs: AnyServiceKey)
    /// Services need each other, in this order.
    case cycle([AnyServiceKey])
    /// A service failed to start; everything already started was stopped.
    case startFailed(service: AnyServiceKey, underlying: any Error)

    public var description: String {
        switch self {
        case .duplicate(let key): "service \(key) is provided twice"
        case .missing(let service, let needs): "service \(service) needs \(needs), which is not in the graph"
        case .cycle(let path): "services depend on each other in a cycle: " + path.map(\.name).joined(separator: " → ")
        case .startFailed(let service, let underlying): "service \(service) failed to start: \(underlying)"
        }
    }
}

/// An application's services, started in dependency order and stopped in
/// reverse: Effect's `Layer`, for apps.
///
///     let database = ServiceKey<Database>("database")
///     let sync = ServiceKey<SyncEngine>("sync")
///
///     let graph = try ServiceGraph(label: "app") {
///         Provide(database) { _ in try await Database.open(url) }
///             stop: { db, _ in await db.close() }
///         Provide(sync, needs: [database.any]) { services in SyncEngine(database: services[database]) }
///             stop: { engine, _ in await engine.flush() }
///     }
///     try await graph.run { services in
///         try await AppModel(sync: services[sync]).run()
///     }
///
/// **Validated when built.** A duplicate key, a dependency on a service that
/// is not in the graph, or a cycle is an error from the initialiser, with
/// the cycle spelled out — before anything starts.
///
/// **Started in order, concurrently where possible.** A service starts as
/// soon as everything it needs has started, so independent services start
/// side by side. Each start is bounded by its `startTimeout` (cooperatively:
/// the start is cancelled when its time is up). If any start fails, the
/// others are cancelled, everything that did start is stopped, and `run`
/// throws ``ServiceGraphError/startFailed(service:underlying:)``.
///
/// **Stopped in reverse, always.** However the body ends, services stop in
/// the reverse of the order they finished starting — so a service stops
/// before anything it needs — through a scope's exit: shielded from
/// cancellation, each bounded, all within `exitBudget`.
public struct ServiceGraph: Sendable {
    public let label: String
    let services: [Provide]
    let order: [AnyServiceKey]

    /// Builds and validates a graph.
    public init(label: String, @ServicesBuilder _ services: () -> [Provide]) throws(ServiceGraphError) {
        self.label = label
        self.services = services()
        self.order = try ServiceGraph.validate(self.services)
    }

    /// The order a sequential start would use: every service after
    /// everything it needs.
    public var startOrder: [AnyServiceKey] { order }

    /// Starts every service, runs `body` with them, and stops them all.
    ///
    /// - Parameters:
    ///   - exitBudget: How long stopping every service may take in all.
    ///   - stopTimeout: How long one stop may take, unless its service says.
    ///   - startGrace: How long a start may run on after it was told to stop
    ///     — by its `startTimeout`, or because the graph is failing or being
    ///     cancelled — before it is abandoned, so a start that ignores
    ///     cancellation cannot hold `run` for ever.
    ///   - body: Runs once every service has started, with them all.
    public func run<R>(
        exitBudget: Duration = .seconds(30),
        stopTimeout: Duration = .seconds(10),
        startGrace: Duration = .seconds(5),
        _ body: nonisolated(nonsending) (Services) async throws -> R
    ) async throws -> R {
        try await withScope(exitBudget: exitBudget, finalizerTimeout: stopTimeout, label: label) { scope in
            let started = try await startAll(grace: startGrace, registeringStopsIn: scope.state)
            return try await body(Services(values: started, visible: nil, owner: nil))
        }
    }

    // MARK: Starting

    private func startAll(grace: Duration, registeringStopsIn scope: ScopeState) async throws -> [AnyServiceKey: any Sendable] {
        let byKey = Dictionary(uniqueKeysWithValues: services.map { ($0.key, $0) })
        var started: [AnyServiceKey: any Sendable] = [:]
        var pending = Set(services.map(\.key))
        var running: Set<AnyServiceKey> = []
        let label = label

        try await withThrowingTaskGroup(of: (AnyServiceKey, any Sendable).self) { group in
            func launchReady() {
                for key in order where pending.contains(key) && !running.contains(key) {
                    let service = byKey[key]!
                    guard service.needs.allSatisfy({ started[$0] != nil }) else { continue }
                    running.insert(key)
                    let visible = Services(values: started, visible: Set(service.needs), owner: key.name)
                    // stoic:allow(unbounded-task-group): an app's few services start as soon as their needs have
                    group.addTask {
                        do {
                            return (key, try await ServiceGraph.start(service, visible: visible, grace: grace, graph: label))
                        } catch {
                            // Cancellation passes through as itself; a start
                            // cut short by its own timeout is a deadline
                            // rejection, not a mysterious CancellationError.
                            if containsCancellation(error), Task.isCancelled { throw error }
                            let underlying = containsCancellation(error)
                                ? Rejection(.deadlineExceeded, label: "\(label).\(key).start")
                                : error
                            Ambient.record(Event("service.start_failed", level: .error, label: label, fields: [
                                .init("service", .string(key.name), privacy: .public),
                                .init("error", .error(underlying)),
                            ]))
                            throw ServiceGraphError.startFailed(service: key, underlying: underlying)
                        }
                    }
                }
            }
            launchReady()
            // After the first failure the other starts are cancelled, but a
            // start may complete anyway; it is drained and registered for
            // its stop like any other, so nothing that started is leaked.
            // The drain is bounded: a start that will not stop is abandoned
            // `grace` after its cancellation.
            var firstFailure: (any Error)?
            while true {
                let next: (AnyServiceKey, any Sendable)?
                do {
                    next = try await group.next()
                } catch {
                    if firstFailure == nil {
                        firstFailure = error
                        group.cancelAll()
                    }
                    continue
                }
                guard let (key, value) = next else { break }
                started[key] = value
                pending.remove(key)
                running.remove(key)
                let service = byKey[key]!
                // Registered as each start completes, so stops run in the
                // reverse of start completion: a service stops before
                // everything it needs.
                scope.register(Finalizer(label: "\(label).\(key).stop", timeout: service.stopTimeout, runsOn: .always) { exit in
                    if let error = await ServiceGraph.stop(service, value, exit: exit, graph: label) { throw error }
                })
                Ambient.record(Event("service.started", level: .debug, label: label, fields: [
                    .init("service", .string(key.name), privacy: .public),
                ]))
                if firstFailure == nil { launchReady() }
            }
            if let firstFailure {
                // A failure caused by the caller's own cancellation is
                // reported as cancellation, unwrapped.
                if Task.isCancelled, case ServiceGraphError.startFailed(_, let underlying) = firstFailure, containsCancellation(underlying) {
                    throw CancellationError()
                }
                throw firstFailure
            }
        }
        return started
    }

    /// Starts one service under its `startTimeout`, which is cooperative. A
    /// start that has not returned `grace` after it was told to stop — by
    /// that timeout, or by the graph's cancellation — is abandoned: listed in
    /// `AbandonedWork` until it ends, reported (`service.start_abandoned`),
    /// and, if it finishes starting after all, stopped at once, since nothing
    /// else will.
    private static func start(_ service: Provide, visible: Services, grace: Duration, graph label: String) async throws -> any Sendable {
        let key = service.key
        let startLabel = "\(label).\(key).start"
        let clock = Ambient.current.clock
        let task = Task<Result<any Sendable, any Error>, Never>.stoic {
            do {
                return .success(try await withTimeout(service.startTimeout, label: startLabel) {
                    // Starts finish in an order the graph must not depend on.
                    await FaultPoint.hit("service.start")
                    return try await service.start(visible)
                })
            } catch {
                return .failure(error)
            }
        }
        if case .finished(let result) = await awaitStart(task, timeout: service.startTimeout, grace: grace, clock: clock) {
            return try result.get()
        }
        let cancelled = Task.isCancelled
        let rejection = Rejection(.deadlineExceeded, label: startLabel)
        let ledger = AbandonedWork.ledger
        let id = ledger.admit(label: "service graph \(label) start \(key)")
        let abandonedAt = clock.now
        // Counted by the graph's scope (and those around it): the start
        // may still hold what they release.
        _ = ledger.abandon(id, deadline: abandonedAt, clock: clock, watch: AbandonmentWatch.current)
        Ambient.record(Event("service.start_abandoned", level: .error, label: label, fields: [
            .init("service", .string(key.name), privacy: .public),
            .init("grace", .duration(grace)),
        ]))
        let exit: Exit = cancelled ? .cancelled : .failure(rejection)
        Task.stoic {
            if case .success(let value) = await task.value {
                _ = await stop(service, value, exit: exit, graph: label)
            }
            if let lateness = ledger.finish(id) {
                Ambient.record(Event("abandoned.completed", level: .notice, label: label, fields: [
                    .init("service", .string(key.name), privacy: .public),
                    .init("late_by", .duration(lateness)),
                ]))
            }
        }
        if cancelled { throw CancellationError() }
        throw rejection
    }

    private enum StartWait: Sendable {
        case finished(Result<any Sendable, any Error>)
        case abandoned
    }

    /// Waits for a start until it finishes, or until `grace` has passed since
    /// it was told to stop: at its `timeout`, or when this task is cancelled.
    private static func awaitStart(
        _ task: Task<Result<any Sendable, any Error>, Never>,
        timeout: Duration,
        grace: Duration,
        clock: AnyClock
    ) async -> StartWait {
        let outcome = OnceCell<StartWait>()
        Task.stoic { outcome.resolve(.finished(await task.value)) }
        let abandon: @Sendable (AnyClock.Instant) -> Task<Void, Never> = { instant in
            Task.stoic {
                do {
                    try await clock.sleep(until: instant, tolerance: nil)
                    outcome.resolve(.abandoned)
                } catch {}
            }
        }
        // The timers, and whether the wait is over: a cancellation that comes
        // after it starts no timer that nothing would cancel.
        let timers = Mutex<(tasks: [Task<Void, Never>], over: Bool)>(([], false))
        timers.withLock { $0.tasks.append(abandon(clock.now.advanced(by: timeout.saturatingAdding(grace)))) }
        let result = await withTaskCancellationHandler {
            await outcome.value
        } onCancel: {
            task.cancel()
            timers.withLock { timers in
                guard !timers.over else { return }
                timers.tasks.append(abandon(clock.now.advanced(by: grace)))
            }
        }
        let started = timers.withLock { timers in
            timers.over = true
            return timers.tasks
        }
        for timer in started { timer.cancel() }
        return result
    }

    /// Stops one service and reports it (`service.stopped`): how long the
    /// stop took and how it went. A stop that hangs is abandoned by the
    /// scope that runs it, and reported when it finally returns.
    ///
    /// - Returns: The stop's error, if it threw.
    static func stop(_ service: Provide, _ value: any Sendable, exit: Exit, graph label: String) async -> (any Error)? {
        let clock = Ambient.current.clock
        let start = clock.now
        func report(_ error: (any Error)?) {
            var fields: [Event.Field] = [
                .init("service", .string(service.key.name), privacy: .public),
                .init("duration", .duration(start.duration(to: clock.now))),
                .init("outcome", .string(error == nil ? "stopped" : "failed"), privacy: .public),
            ]
            if let error { fields.append(.init("error", .error(error))) }
            Ambient.record(Event("service.stopped", level: error == nil ? .info : .warning, label: label, fields: fields))
        }
        do {
            try await service.stop(value, exit)
            report(nil)
            return nil
        } catch {
            report(error)
            return error
        }
    }

    // MARK: Validation

    private static func validate(_ services: [Provide]) throws(ServiceGraphError) -> [AnyServiceKey] {
        var byKey: [AnyServiceKey: Provide] = [:]
        for service in services {
            if byKey[service.key] != nil { throw .duplicate(service.key) }
            byKey[service.key] = service
        }
        for service in services {
            for need in service.needs where byKey[need] == nil {
                throw .missing(service: service.key, needs: need)
            }
        }
        // Depth-first topological sort in declaration order, reporting the
        // first cycle found as a path.
        enum Mark { case visiting, done }
        var marks: [AnyServiceKey: Mark] = [:]
        var order: [AnyServiceKey] = []
        var stack: [AnyServiceKey] = []

        func visit(_ key: AnyServiceKey) throws(ServiceGraphError) {
            switch marks[key] {
            case .done: return
            case .visiting:
                let start = stack.firstIndex(of: key) ?? 0
                throw .cycle(Array(stack[start...]) + [key])
            case nil:
                marks[key] = .visiting
                stack.append(key)
                for need in byKey[key]!.needs { try visit(need) }
                stack.removeLast()
                marks[key] = .done
                order.append(key)
            }
        }
        for service in services { try visit(service.key) }
        return order
    }
}
