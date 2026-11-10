#if os(macOS)
public import Stoic
internal import Foundation
internal import Synchronization

/// How a service runs: when it exits idle, how long a handler may ignore
/// cancellation, and how it exits.
public struct XPCHostPolicy: Sendable {
    /// Exit after this long with nothing in flight and nothing held; `nil`
    /// to stay until the system or the app ends the process.
    public var idleExit: Duration?

    /// How long past its budget a handler may run, ignoring its
    /// cancellation, before the service exits: measured on the liveness
    /// clock, so a Mac asleep wedges nothing.
    public var watchdogGrace: Duration

    /// How the process exits. `_exit` by default: what a model's
    /// destructors would do on the way out is not worth waiting for, and
    /// nothing a service holds outlives it.
    public var exit: @Sendable (Int32) -> Never

    /// - Parameters:
    ///   - idleExit: Exit after this long idle; `nil` never to.
    ///   - watchdogGrace: How long past its budget a handler may run.
    ///   - exit: How the process exits; `_exit` when `nil`.
    public init(idleExit: Duration? = nil, watchdogGrace: Duration = .seconds(10), exit: (@Sendable (Int32) -> Never)? = nil) {
        precondition(idleExit.map { $0 > .zero } ?? true, "XPCHostPolicy: idleExit must be positive")
        precondition(watchdogGrace >= .zero, "XPCHostPolicy: watchdogGrace must not be negative")
        self.idleExit = idleExit
        self.watchdogGrace = watchdogGrace
        self.exit = exit ?? { _exit($0) }
    }

    /// No idle exit; a 10 s watchdog grace; `_exit`.
    public static let standard = XPCHostPolicy()
}

/// What a handler knows about the request it is answering.
public struct XPCRequestContext: Sendable {
    /// The request's id on its session.
    public let id: UInt64

    /// The method's wire name.
    public let method: String

    /// For a `.keyed` method, the key every attempt of the call sends:
    /// deduplicate by it.
    public let idempotencyKey: IdempotencyKey?

    /// The time the caller had left when it sent the request: the handler
    /// runs under it as its deadline. `nil` if the caller had no deadline.
    public let budget: Duration?
}

/// The service's side: one per service process (design/25).
///
///     let host = XPCHost(build: Build.id, policy: XPCHostPolicy(idleExit: .seconds(30)))
///     host.handle(ModelsAPI.respond) { request, _ throws(ModelsFailure) in try await engine.respond(request) }
///     host.handle(ModelsAPI.stats) { _, _ in engine.stats }
///     host.run()
///
/// Each request runs in its own task, under the deadline its caller had
/// left, and is answered exactly once: the reply, the handler's declared
/// failure, "cancelled", or a refusal (an unknown method, a request that
/// does not decode, a client of another build, a service that is exiting).
/// A message is never let go unanswered, because that would end the
/// client's session. A watchdog, on a queue of its own, exits the process
/// when a handler runs past its budget and the grace: in a sandbox, where
/// the app cannot kill its service, that is the only way a wedged service
/// ends.
public final class XPCHost: Sendable {
    /// The service's build, which the app's must equal.
    public let build: String

    let policy: XPCHostPolicy

    /// The context the host was made in, for its handlers and events.
    let ambient: Ambient

    private struct InFlight {
        let task: Task<Void, Never>
        let method: String
        let overdueAt: AnyClock.Instant?
    }

    private struct State {
        var handlers: [String: Handler] = [:]
        var runtime: HostRuntime?
        var inFlight: [RequestKey: InFlight] = [:]
        var holds: Set<String> = []
        var exiting = false
        var idleSince: AnyClock.Instant?
        var idleTimerArmed = false
        var nextSession: UInt64 = 0
    }

    private struct RequestKey: Hashable {
        let session: UInt64
        let id: UInt64
    }

    /// One method's handler, its types erased.
    private struct Handler: Sendable {
        let start: @Sendable (_ message: any HostMessage, _ header: WireHeader, _ session: HostSession, _ host: XPCHost) -> Void
    }

    private let state = Mutex(State())

    /// - Parameters:
    ///   - build: The service's build: the same compiled-in value the app
    ///     gives its ``XPCPeer``.
    ///   - policy: Idle exit, watchdog grace, and how to exit.
    public init(build: String, policy: XPCHostPolicy = .standard) {
        self.build = build
        self.policy = policy
        self.ambient = Ambient.current
    }

    // MARK: Declaring

    /// Answers `method` with `handler`.
    ///
    /// The handler runs in a task of its own, under the deadline its caller
    /// had left, and is cancelled when the caller cancels or its session
    /// ends. What it returns is the reply; the failure it throws reaches the
    /// caller typed. One handler per method: a second is a bug.
    public func handle<Request, Reply, Failure>(
        _ method: XPCMethod<Request, Reply, Failure>,
        _ handler: @escaping @Sendable (Request, XPCRequestContext) async throws(Failure) -> Reply
    ) {
        let name = method.name
        let entry = Handler { message, header, session, host in
            let request: Request
            do {
                request = try message.decode(WirePayload<Request>.self).payload
            } catch {
                host.refuse(message, .undecodable, method: name, detail: "the request to \(name) did not decode: \(error)")
                return
            }
            host.start(header, method: name, session: session, message: message) { context in
                do throws(Failure) {
                    return Answer<Reply, Failure>(status: .success, reply: try await handler(request, context))
                } catch {
                    if Task.isCancelled { return Answer<Reply, Failure>(status: .cancelled) }
                    return Answer<Reply, Failure>(status: .failure, failure: error)
                }
            }
        }
        let added = state.withLock { state -> Bool in
            guard state.handlers[name] == nil else { return false }
            state.handlers[name] = entry
            return true
        }
        precondition(added, "XPCHost: \(name) has a handler already")
    }

    /// Keeps an idle service from exiting while `reason` is held: a model
    /// it has loaded. Holding a reason twice holds it once. A service that
    /// has already decided to exit is not kept.
    public func hold(_ reason: String) {
        state.withLock { state in
            state.holds.insert(reason)
            // Not idle while it is held: the idle period starts again at the
            // release.
            state.idleSince = nil
        }
    }

    /// Lets go of `reason`; with nothing held and nothing in flight, the
    /// idle period starts.
    public func release(_ reason: String) {
        state.withLock { _ = $0.holds.remove(reason) }
        settleIfIdle()
    }

    // MARK: Running

    /// Listens as the bundled service `service` (the service's own bundle
    /// identifier by default) and never returns: the process ends through
    /// the policy's `exit`, when the app asks, when idle, or when the
    /// watchdog fires.
    public func run(service: String? = nil) -> Never {
        SystemListener.run(self, service: service ?? Bundle.main.bundleIdentifier ?? "")
    }

    /// Serves under `runtime`: the system's process, or a simulated one.
    func attach(_ runtime: HostRuntime) {
        state.withLock { $0.runtime = runtime }
        report("xpc.host_started", .info, label: nil, [
            .init("build", .string(build), privacy: .public), .init("pid", .int(Int(runtime.pid))),
        ])
        settleIfIdle()
    }

    /// A session opened.
    func openSession() -> HostSession {
        state.withLock { state in
            defer { state.nextSession += 1 }
            return HostSession(id: state.nextSession)
        }
    }

    /// A session ended: its client left. Its handlers are cancelled.
    func sessionEnded(_ session: HostSession) {
        let tasks = state.withLock { state in
            state.inFlight.filter { $0.key.session == session.id }.map(\.value.task)
        }
        for task in tasks { task.cancel() }
    }

    // MARK: Messages

    /// One message from a client, on the listener's queue: decoded and
    /// dispatched at once, never awaited here.
    func receive(_ message: any HostMessage, on session: HostSession) {
        let header: WireHeader
        do {
            header = try message.decode(WireHeader.self)
        } catch {
            if message.expectsReply { refuse(message, .undecodable, method: nil, detail: "the message did not decode: \(error)") }
            return
        }
        switch header.kind {
        case .hello:
            let exiting = state.withLock { $0.exiting }
            if let client = header.build, client != build {
                session.mismatched(client)
                report("xpc.build_mismatch", .error, label: nil, [
                    .init("expected", .string(build), privacy: .public), .init("found", .string(client), privacy: .public),
                ])
            }
            // An exiting service still says who it is: the peer may have to
            // kill it if it lingers.
            let welcome = Welcome(pid: runtimePID, build: build)
            message.reply(Answer<Welcome, XPCEmpty>(status: exiting ? .exiting : .welcome, reply: welcome))
        case .call:
            let method = header.method ?? ""
            if session.clientBuild.map({ $0 != build }) ?? false {
                refuse(message, .buildMismatch, method: method, detail: build)
                return
            }
            let (exiting, handler) = state.withLock { ($0.exiting, $0.handlers[method]) }
            if exiting {
                refuse(message, .exiting, method: method, detail: nil)
            } else if let handler {
                handler.start(message, header, session, self)
            } else {
                refuse(message, .unknownMethod, method: method, detail: nil)
            }
        case .cancel:
            let task = state.withLock { $0.inFlight[RequestKey(session: session.id, id: header.id)]?.task }
            if let task {
                task.cancel()
            } else {
                report("xpc.cancel_unknown", .debug, label: nil, [.init("id", .int(Int(truncatingIfNeeded: header.id)))])
            }
        case .end:
            exit(0, event: "xpc.host_exiting", level: .info, fields: [])
        }
    }

    private var runtimePID: Int32 {
        state.withLock { $0.runtime?.pid ?? 0 }
    }

    private func refuse(_ message: any HostMessage, _ status: AnswerStatus, method: String?, detail: String?) {
        var fields: [Event.Field] = [.init("reason", .string(status.rawValue), privacy: .public)]
        if let method { fields.append(.init("method", .string(method), privacy: .public)) }
        report("xpc.request_refused", .notice, label: method, fields)
        message.reply(Answer<XPCEmpty, XPCEmpty>(status: status, detail: detail))
    }

    /// Runs one request in its own task, under its caller's budget, and
    /// answers it once.
    private func start(
        _ header: WireHeader, method: String, session: HostSession, message: any HostMessage,
        _ work: @escaping @Sendable (XPCRequestContext) async -> any Encodable & Sendable
    ) {
        let budget = header.budgetNanoseconds.map { Duration.nanoseconds(max(0, $0)) }
        let context = XPCRequestContext(id: header.id, method: method, idempotencyKey: header.key.map(IdempotencyKey.init(rawValue:)), budget: budget)
        let key = RequestKey(session: session.id, id: header.id)
        let overdueAt = budget.map { ambient.livenessClock.now.advanced(by: $0).advanced(by: policy.watchdogGrace) }
        let ambient = ambient
        // Admitted under the lock that decides an exit, so a request is
        // either refused "exiting" or in flight when the decision is made:
        // never accepted by a process that has already decided to go.
        let admitted = state.withLock { state -> (admitted: Bool, runtime: HostRuntime?) in
            guard !state.exiting else { return (false, nil) }
            state.idleSince = nil
            // A task of the host's: the handler runs under its caller's budget
            // and in the host's context, and inherits nothing else.
            let task = Task.owned(in: ambient) {
                let answer: any Encodable & Sendable
                if let budget {
                    answer = await withTimeout(budget, clock: ambient.clock) { await work(context) }
                } else {
                    answer = await work(context)
                }
                self.finish(key)
                message.reply(answer)
            }
            state.inFlight[key] = InFlight(task: task, method: method, overdueAt: overdueAt)
            return (true, state.runtime)
        }
        guard admitted.admitted else {
            refuse(message, .exiting, method: method, detail: nil)
            return
        }
        if let overdueAt { admitted.runtime?.watch(overdueAt) }
    }

    private func finish(_ key: RequestKey) {
        state.withLock { _ = $0.inFlight.removeValue(forKey: key) }
        settleIfIdle()
    }

    /// The process is gone (simulated): its handlers stop, and nothing
    /// new starts.
    func processEnded() {
        let tasks = state.withLock { state in
            state.exiting = true
            return state.inFlight.values.map(\.task)
        }
        for task in tasks { task.cancel() }
    }

    // MARK: The watchdog

    /// Exits if a handler has run past its budget and the grace. The
    /// runtime calls it from a queue of its own.
    func checkWatchdog() {
        let now = ambient.livenessClock.now
        let overdue = state.withLock { state -> (method: String, by: Duration)? in
            guard !state.exiting else { return nil }
            let late = state.inFlight.values.compactMap { request -> (String, Duration)? in
                guard let overdueAt = request.overdueAt, overdueAt <= now else { return nil }
                return (request.method, overdueAt.duration(to: now))
            }
            return late.max { $0.1 < $1.1 }
        }
        guard let overdue else { return }
        exit(1, event: "xpc.watchdog_exit", level: .error, fields: [
            .init("method", .string(overdue.method), privacy: .public), .init("grace", .duration(policy.watchdogGrace)),
            .init("overdue", .duration(overdue.by)),
        ])
    }

    // MARK: Idle exit

    /// Starts the idle period if the service is idle, and the timer that
    /// ends it if none runs.
    private func settleIfIdle() {
        guard let idleExit = policy.idleExit else { return }
        let arm = state.withLock { state -> Bool in
            guard state.runtime != nil, !state.exiting, state.inFlight.isEmpty, state.holds.isEmpty else { return false }
            if state.idleSince == nil { state.idleSince = ambient.clock.now }
            guard !state.idleTimerArmed else { return false }
            state.idleTimerArmed = true
            return true
        }
        guard arm else { return }
        Task.owned(in: ambient) { await self.idleTimer(idleExit) }
    }

    /// Waits out the idle period, which activity puts off; exits if it
    /// ends with the service still idle.
    private func idleTimer(_ idleExit: Duration) async {
        while true {
            let wakeAt = state.withLock { state -> AnyClock.Instant? in
                guard let since = state.idleSince, !state.exiting else {
                    state.idleTimerArmed = false
                    return nil
                }
                return since.advanced(by: idleExit)
            }
            guard let wakeAt else { return }
            do {
                try await ambient.clock.sleep(until: wakeAt)
            } catch {
                state.withLock { $0.idleTimerArmed = false }
                return
            }
            if exit(0, event: "xpc.idle_exit", level: .info, fields: [.init("idle", .duration(idleExit))], ifIdleFor: idleExit) {
                return
            }
        }
    }

    // MARK: Exit

    /// Decides to exit, once: from here every request is refused
    /// "exiting", and the runtime ends the process. With `ifIdleFor`, only
    /// if the service has been idle that long, decided under the same lock
    /// that admits requests. Returns whether this call decided it.
    @discardableResult
    private func exit(_ code: Int32, event: EventName, level: Event.Level, fields: [Event.Field], ifIdleFor idle: Duration? = nil) -> Bool {
        let now = ambient.clock.now
        let runtime = state.withLock { state -> HostRuntime? in
            guard !state.exiting else { return nil }
            if let idle {
                guard state.inFlight.isEmpty, state.holds.isEmpty, let since = state.idleSince, since.advanced(by: idle) <= now else {
                    // Not idle (long enough): the timer looks again, or
                    // disarms if the idle period has not started.
                    if !state.inFlight.isEmpty || !state.holds.isEmpty { state.idleSince = nil }
                    return nil
                }
            }
            state.exiting = true
            return state.runtime
        }
        guard let runtime else { return false }
        report(event, level, label: nil, fields)
        runtime.exit(code)
        return true
    }

    func report(_ name: EventName, _ level: Event.Level, label: String?, _ fields: [Event.Field]) {
        let instrumentation = ambient.instrumentation
        guard instrumentation.isEnabled(level) else { return }
        instrumentation.record(Event(name, level: level, label: label ?? "service", fields: fields))
    }
}

/// One client session, as the host sees it.
final class HostSession: Sendable {
    let id: UInt64
    private let build = Mutex<String?>(nil)

    init(id: UInt64) {
        self.id = id
    }

    /// The client's build, if it said one that is not the service's.
    var clientBuild: String? {
        build.withLock { $0 }
    }

    func mismatched(_ client: String) {
        build.withLock { $0 = client }
    }
}

/// A message a host received: decoded on the listener's queue, answered
/// once, from anywhere.
protocol HostMessage: Sendable {
    func decode<T: Decodable>(_ type: T.Type) throws -> T
    var expectsReply: Bool { get }
    /// Answers the message; a second answer is ignored.
    func reply(_ answer: some Encodable & Sendable)
}

/// What a host runs under: the system's process, or a simulated one.
struct HostRuntime: Sendable {
    /// The process's pid.
    let pid: Int32

    /// Ends the process, off any queue a request holds.
    let exit: @Sendable (Int32) -> Void

    /// Arranges for ``XPCHost/checkWatchdog()`` to run by `instant` on the
    /// liveness clock. The system's runtime checks on a timer instead.
    let watch: @Sendable (AnyClock.Instant) -> Void
}
#endif
