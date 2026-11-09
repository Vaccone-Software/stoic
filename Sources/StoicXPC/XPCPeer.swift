#if os(macOS)
public import Stoic
internal import Synchronization

/// How long a peer waits for a service to start and to end.
public struct XPCPeerPolicy: Sendable, Hashable {
    /// The longest a run's handshake may take: launchd's start of a new
    /// process, and its answer. Longer than launchd's relaunch delay for a
    /// service that lived under ten seconds.
    public var handshakeTimeout: Duration

    /// How long a run asked to end is given to exit before it is killed.
    public var endGrace: Duration

    /// How long a killed run is given to be gone before it is declared
    /// wedged.
    public var killGrace: Duration

    public init(handshakeTimeout: Duration = .seconds(20), endGrace: Duration = .seconds(2), killGrace: Duration = .seconds(1)) {
        precondition(handshakeTimeout > .zero && endGrace >= .zero && killGrace >= .zero, "XPCPeerPolicy: durations must not be negative")
        self.handshakeTimeout = handshakeTimeout
        self.endGrace = endGrace
        self.killGrace = killGrace
    }

    /// 20 s to start, 2 s to exit, 1 s to die once killed.
    public static let standard = XPCPeerPolicy()
}

/// How the end of a run came about.
public enum XPCEndResult: Sendable, Hashable, CustomStringConvertible {
    /// There was no run to end.
    case notRunning
    /// The run exited as asked, within its grace.
    case exited
    /// The run did not exit in time and was killed.
    case killed
    /// The run would not go: it could not be killed (a sandboxed app cannot
    /// signal its service), or did not die. Calls fail at once until it goes.
    case wedged
    /// The caller stopped waiting; the end goes on without it.
    case inProgress

    public var description: String {
        switch self {
        case .notRunning: "not running"
        case .exited: "exited"
        case .killed: "killed"
        case .wedged: "wedged"
        case .inProgress: "in progress"
        }
    }
}

/// The app's side of one XPC service: the service's lifecycle, made
/// explicit, and the one way to call it (design/25).
///
///     let models = XPCPeer(service: "com.example.app.models", build: Build.id)
///     let text = try await models.call(ModelsAPI.respond, Generate(prompt))
///
/// A *run* is one process of the service, from the handshake that starts it
/// to the first sign that it is gone. The peer starts a run when a call needs
/// one, never while the last one is still exiting, and fails every call
/// waiting on a run the moment it is lost. Every call runs through its
/// method's declared operation (design/22), so its deadline, retries,
/// breaker and admission are the operation's, and a failure says whether the
/// request reached the service.
///
/// One peer per service per process: the service's process belongs to it.
public final class XPCPeer: Sendable {
    /// The service's name: its bundle identifier in `Contents/XPCServices`.
    public let service: String

    /// The app's build, which the service's must equal.
    public let build: String

    let policy: XPCPeerPolicy
    let transport: any XPCTransport

    /// The context the peer was made in: its clocks and instrumentation,
    /// for work and events that happen on XPC's queues or the peer's own
    /// tasks, outside any caller.
    let ambient: Ambient

    private enum Phase {
        case idle
        case starting(RunState)
        case running(RunState)
        case ending(RunState)
        case wedged(RunState)
        case mismatched(expected: String, found: String)
        case shutDown

        var run: RunState? {
            switch self {
            case .starting(let run), .running(let run), .ending(let run), .wedged(let run): run
            case .idle, .mismatched, .shutDown: nil
            }
        }
    }

    private struct State {
        var phase = Phase.idle
        var runs = 0
        /// When the last run started and ended, for the relaunch delay.
        var lastRun: (started: AnyClock.Instant, ended: AnyClock.Instant)?
    }

    private let state = Mutex(State())
    private let requestIDs = Atomic<UInt64>(0)
    /// Whether the peer still counts in ``services``: it gives the service up
    /// once, at shutdown or when released.
    private let registered: Atomic<Bool>

    /// How many peers each service has in this process.
    private static let services = Mutex<[String: Int]>([:])

    /// launchd's delay before restarting a service whose last run lived
    /// less than this, measured on macOS 27 (design/25, Origin). Reported,
    /// never relied on.
    static let relaunchThrottle = Duration.seconds(10)

    /// A peer for the bundled service `service`.
    ///
    /// - Parameters:
    ///   - service: The service's bundle identifier.
    ///   - build: The app's build: a value compiled into a module the app
    ///     and the service both import, so both are given the same one only
    ///     when they were built together.
    ///   - policy: How long to wait for the service to start and to end.
    public convenience init(service: String, build: String, policy: XPCPeerPolicy = .standard) {
        self.init(service: service, build: build, policy: policy, transport: SystemTransport(service: service), registers: true)
    }

    /// A peer over `transport`: ``XPCSimulatedService`` in tests.
    public convenience init(service: String, build: String, policy: XPCPeerPolicy = .standard, transport: any XPCTransport) {
        self.init(service: service, build: build, policy: policy, transport: transport, registers: false)
    }

    private init(service: String, build: String, policy: XPCPeerPolicy, transport: any XPCTransport, registers: Bool) {
        self.service = service
        self.build = build
        self.policy = policy
        self.transport = transport
        self.ambient = Ambient.current
        self.registered = Atomic(registers)
        if registers {
            let others = Self.services.withLock { services in
                defer { services[service, default: 0] += 1 }
                return services[service] ?? 0
            }
            if others > 0 {
                report("xpc.peer_duplicate", .error, [.init("service", .string(service), privacy: .public)])
            }
        }
    }

    // A peer released without `shutdown()` still owns a session and the
    // process behind it: the session is cancelled here (synchronously, as
    // releasing a live one traps), which ends the run, and the service is
    // given up.
    deinit {
        let run = state.withLock { $0.phase.run }
        if let run, let ended = run.end() {
            for fail in ended.failures { fail() }
            ended.connection?.cancel()
        }
        unregister()
    }

    private func unregister() {
        guard registered.exchange(false, ordering: .relaxed) else { return }
        Self.services.withLock { services in
            let remaining = (services[service] ?? 1) - 1
            services[service] = remaining > 0 ? remaining : nil
        }
    }

    /// The live run, if there is one.
    public var run: XPCRun? {
        state.withLock { state in
            if case .running(let run) = state.phase { return run.info }
            return nil
        }
    }

    // MARK: Calls

    /// Calls `method` with `request` and returns the service's reply.
    ///
    /// The call is a `perform` of the method's operation: its deadline,
    /// retries by its repeat safety, breaker and admission are derived as
    /// for any declared operation (design/22). Each attempt waits for a live
    /// run — starting one if there is none, and waiting out one that is
    /// exiting — then sends the request with the time left before the
    /// deadline, and waits for the reply or its own cancellation. A caller
    /// that leaves after the request was sent returns at once, and the
    /// service is told to cancel it.
    ///
    /// - Parameters:
    ///   - method: The method, as declared in the module both sides import.
    ///   - request: Its request.
    ///   - ifRunning: Fail `.notRunning` at once, starting nothing, unless a
    ///     run is live: a read that must not launch the service.
    ///   - idempotencyKey: For a `.keyed` method, the key made with the
    ///     intent; the handler reads it from its context.
    ///   - fileID: The call site, captured for events.
    ///   - line: The call site, captured for events.
    /// - Throws: `OperationError`, whose `last` is the ``XPCCallError`` of
    ///   the last attempt, and whose `outcome` says whether the service may
    ///   have acted.
    public nonisolated(nonsending) func call<Request, Reply, Failure>(
        _ method: XPCMethod<Request, Reply, Failure>,
        _ request: Request,
        ifRunning: Bool = false,
        idempotencyKey: IdempotencyKey? = nil,
        fileID: String = #fileID,
        line: UInt = #line
    ) async throws(OperationError<XPCCallError<Failure>>) -> Reply {
        let keyed = method.operation.safety == .keyed
        return try await method.operation.perform(idempotencyKey: idempotencyKey, fileID: fileID, line: line) {
            attempt async throws(XPCCallError<Failure>) -> Reply in
            try await self.attempt(method, request, ifRunning: ifRunning, key: keyed ? attempt.idempotencyKey : nil)
        }
    }

    /// The outcome of one request, as its attempt sees it.
    private enum Delivery<Reply: Codable & Sendable, Failure: Codable & Sendable>: Sendable {
        case delivered(Result<Answer<Reply, Failure>, XPCDeliveryFailure>)
        case lost
        case cancelled
    }

    private func attempt<Request, Reply, Failure>(
        _ method: XPCMethod<Request, Reply, Failure>, _ request: Request, ifRunning: Bool, key: IdempotencyKey?
    ) async throws(XPCCallError<Failure>) -> Reply {
        let run = try await liveRun(ifRunning: ifRunning, as: Failure.self)
        guard !Task.isCancelled, let connection = run.connection else { throw .cancelled(afterSending: false) }
        let id = requestIDs.add(1, ordering: .relaxed).newValue
        let message = Outgoing(
            kind: .call, id: id, method: method.name, budgetNanoseconds: Deadline.current?.remaining.wireNanoseconds,
            key: key?.rawValue, payload: request)
        let slot = ReplySlot<Delivery<Reply, Failure>>()
        guard run.register(id, fail: { slot.settle(.lost) }) else { throw .lost(afterSending: false) }
        do {
            try connection.send(message) { [self] (result: Result<Answer<Reply, Failure>, XPCDeliveryFailure>) in
                // A connection lost is no answer, and the first sign that the
                // run is gone: the run's end fails this request with the
                // others in flight, and counts it.
                if case .failure(.connectionLost) = result {
                    runGone(run)
                    return
                }
                run.answered(id)
                if !slot.settle(.delivered(result)), case .success = result {
                    report("xpc.late_reply", .debug, [.init("method", .string(method.name), privacy: .public), .init("run", .int(run.number))])
                }
            }
        } catch {
            run.finished(id)
            switch error {
            case .connectionLost:
                // The session is over though its end has not been heard
                // yet: the run is gone, and the next attempt starts another.
                runGone(run)
                throw .lost(afterSending: false)
            case .undecodable(let why): throw .refused("the request to \(method.name) did not encode: \(why)")
            }
        }

        switch await slot.wait(cancelled: { .cancelled }) {
        case .cancelled:
            abandon(id, on: run, connection: connection, method: method)
            throw .cancelled(afterSending: true)
        case .lost, .delivered(.failure(.connectionLost)):
            // An end the app decided (`end`, a stuck request, `shutdown`) is
            // not the service failing.
            throw run.endedByApp ? .ended(afterSending: true) : .lost(afterSending: true)
        case .delivered(.failure(.undecodable(let why))):
            run.finished(id)
            throw .protocolViolation("the reply from \(method.name) did not decode: \(why)")
        case .delivered(.success(let answer)):
            run.finished(id)
            return try interpret(answer, of: method, on: run)
        }
    }

    private func interpret<Request, Reply, Failure>(
        _ answer: Answer<Reply, Failure>, of method: XPCMethod<Request, Reply, Failure>, on run: RunState
    ) throws(XPCCallError<Failure>) -> Reply {
        switch answer.status {
        case .success:
            guard let reply = answer.reply else { throw .protocolViolation("\(method.name) answered success with no reply") }
            return reply
        case .failure:
            guard let failure = answer.failure else { throw .protocolViolation("\(method.name) answered failure with none") }
            throw .failed(failure)
        case .cancelled:
            // The service cancelled it on its own: its budget passed on its
            // clock first, or its session ended. It may have acted.
            throw .lost(afterSending: true)
        case .exiting:
            // The run decided to exit before this request: it was not run.
            exiting(run)
            throw .lost(afterSending: false)
        case .unknownMethod:
            throw .refused("the service has no method \(method.name)")
        case .undecodable:
            throw .refused(answer.detail ?? "the request to \(method.name) did not decode in the service")
        case .badReply:
            throw .protocolViolation(answer.detail ?? "the reply from \(method.name) did not encode in the service")
        case .buildMismatch:
            throw .buildMismatch(expected: build, found: answer.detail ?? "unknown")
        case .welcome:
            throw .protocolViolation("\(method.name) was answered with a handshake")
        }
    }

    /// The caller of request `id` left: tells the service, and watches for
    /// a stuck request if the method says what that means.
    private func abandon<Request, Reply, Failure>(
        _ id: UInt64, on run: RunState, connection: any XPCConnection, method: XPCMethod<Request, Reply, Failure>
    ) {
        guard run.abandon(id) else { return }
        do {
            try connection.send(Outgoing<XPCEmpty>(kind: .cancel, id: id))
        } catch {
            // The session has ended: the run's end clears the request.
            return
        }
        guard case .endService(let after) = method.ifStuck else { return }
        let name = method.name
        background { [self] in
            do {
                try await ambient.livenessClock.sleep(for: after)
            } catch {
                return
            }
            guard run.isStillUnanswered(id) else { return }
            report("xpc.call_stuck", .warning, [
                .init("method", .string(name), privacy: .public), .init("run", .int(run.number)), .init("after", .duration(after)),
            ])
            _ = await self.end(run, reason: "\(name) was stuck", byApp: true)
        }
    }

    // MARK: Runs

    /// The live run, started or waited for.
    private func liveRun<Failure>(ifRunning: Bool, as _: Failure.Type) async throws(XPCCallError<Failure>) -> RunState {
        // Each pass waits for a run to start or to go; a run that answers
        // "exiting" sends the caller round once more. A deadline bounds it,
        // and so does the bound here.
        for _ in 0..<8 {
            let next = state.withLock { state -> NextStep<Failure> in
                switch state.phase {
                case .idle:
                    if ifRunning { return .fail(.notRunning) }
                    state.runs += 1
                    let run = RunState(number: state.runs, startedAt: ambient.clock.now)
                    state.phase = .starting(run)
                    return .start(run)
                case .starting(let run):
                    return ifRunning ? .fail(.notRunning) : .waitReady(run)
                case .running(let run):
                    return .use(run)
                case .ending(let run):
                    return ifRunning ? .fail(.notRunning) : .waitSettled(run)
                case .wedged:
                    return .fail(.unavailable(.wedged))
                case .mismatched(let expected, let found):
                    return .fail(.buildMismatch(expected: expected, found: found))
                case .shutDown:
                    return .fail(.unavailable(.shutDown))
                }
            }
            switch next {
            case .use(let run):
                return run
            case .fail(let error):
                throw error
            case .start(let run):
                startRun(run)
                if let run = try await ready(run, as: Failure.self) { return run }
            case .waitReady(let run):
                if let run = try await ready(run, as: Failure.self) { return run }
            case .waitSettled(let run):
                guard await run.settled.wait() != nil else { throw .cancelled(afterSending: false) }
            }
        }
        throw .lost(afterSending: false)
    }

    /// What a call does next to have a live run.
    private enum NextStep<Failure: Error & Sendable> {
        case use(RunState)
        case start(RunState)
        case waitReady(RunState)
        case waitSettled(RunState)
        case fail(XPCCallError<Failure>)
    }

    /// The run, once its handshake is decided; `nil` to look again.
    private func ready<Failure>(_ run: RunState, as _: Failure.Type) async throws(XPCCallError<Failure>) -> RunState? {
        guard let readiness = await run.ready.wait() else { throw .cancelled(afterSending: false) }
        switch readiness {
        case .live: return run
        case .lost: throw .lost(afterSending: false)
        case .retry: return nil
        case .unavailable(let why): throw .unavailable(why)
        case .buildMismatch(let expected, let found): throw .buildMismatch(expected: expected, found: found)
        }
    }

    /// Opens a session for `run` and shakes hands, on the peer's behalf:
    /// bounded by the handshake timeout, not by the deadline of the caller
    /// that happened to start it.
    private func startRun(_ run: RunState) {
        let throttled = state.withLock { state -> Duration? in
            guard let last = state.lastRun, last.started.duration(to: last.ended) < Self.relaunchThrottle else { return nil }
            let wait = ambient.clock.now.duration(to: last.started.advanced(by: Self.relaunchThrottle))
            return wait > .zero ? wait : nil
        }
        if let throttled {
            report("xpc.relaunch_throttled", .notice, [.init("run", .int(run.number)), .init("expected_wait", .duration(throttled))])
        }
        background { [self] in await handshake(run) }
    }

    private enum Hello: Sendable {
        case answered(Result<Answer<Welcome, XPCEmpty>, XPCDeliveryFailure>)
        case timedOut
    }

    private func handshake(_ run: RunState) async {
        let connection: any XPCConnection
        do {
            connection = try transport.connect(onEnd: { [weak self] in self?.runGone(run) })
        } catch {
            handshakeFailed(run, why: error.reason, readiness: .unavailable(.noSession(error.reason)))
            return
        }
        guard run.attach(connection) else {
            connection.cancel()
            return
        }
        let slot = ReplySlot<Hello>()
        do {
            try connection.send(Outgoing<XPCEmpty>(kind: .hello, build: build)) { (result: Result<Answer<Welcome, XPCEmpty>, XPCDeliveryFailure>) in
                slot.settle(.answered(result))
            }
        } catch {
            slot.settle(.answered(.failure(error)))
        }
        let hello = await withTimeout(policy.handshakeTimeout, clock: ambient.clock) {
            await slot.wait(cancelled: { .timedOut })
        }
        switch hello {
        case .answered(.success(let answer)):
            welcomed(run, answer: answer, connection: connection)
        case .answered(.failure(.connectionLost(let why))):
            report("xpc.handshake_failed", .warning, [.init("run", .int(run.number)), .init("reason", .string("lost: \(why)"))])
            runGone(run)
        case .answered(.failure(.undecodable(let why))):
            handshakeFailed(run, why: "the handshake did not decode: \(why)", readiness: .unavailable(.noHandshake("its answer did not decode")))
            connection.cancel()
        case .timedOut:
            report("xpc.handshake_failed", .warning, [
                .init("run", .int(run.number)), .init("reason", .string("no answer within \(policy.handshakeTimeout)"), privacy: .public),
            ])
            // The run is gone to the peer (calls retry with another), and its
            // session cancelled with it.
            runGone(run)
        }
    }

    private func welcomed(_ run: RunState, answer: Answer<Welcome, XPCEmpty>, connection: any XPCConnection) {
        switch answer.status {
        case .welcome:
            guard let welcome = answer.reply else {
                handshakeFailed(run, why: "a welcome with no build", readiness: .unavailable(.noHandshake("its answer was empty")))
                connection.cancel()
                return
            }
            guard welcome.build == build else {
                mismatch(run, found: welcome.build, connection: connection)
                return
            }
            let info = XPCRun(number: run.number, pid: welcome.pid, build: welcome.build)
            run.setInfo(info)
            let current = state.withLock { state -> Bool in
                guard case .starting(let starting) = state.phase, starting === run else { return false }
                state.phase = .running(run)
                return true
            }
            guard current else {
                // Shut down while it started, or lost: whoever changed the
                // phase decided what its waiters see; this only agrees.
                run.ready.open(isShutDown ? .unavailable(.shutDown) : .lost)
                connection.cancel()
                return
            }
            report("xpc.run_started", .info, [
                .init("run", .int(run.number)), .init("pid", .int(Int(welcome.pid))),
                .init("build", .string(welcome.build), privacy: .public),
                .init("took", .duration(run.startedAt.duration(to: ambient.clock.now))),
            ])
            run.ready.open(.live(info))
        case .exiting:
            // The process that answered is the last one, still leaving. Its
            // pid comes with the answer, so the end can kill it if it lingers.
            if let welcome = answer.reply {
                run.setInfo(XPCRun(number: run.number, pid: welcome.pid, build: welcome.build))
            }
            exiting(run)
            run.ready.open(.retry)
        case .buildMismatch:
            mismatch(run, found: answer.detail ?? "unknown", connection: connection)
        case .success, .failure, .cancelled, .unknownMethod, .undecodable, .badReply:
            handshakeFailed(run, why: "the handshake was answered \(answer.status.rawValue)", readiness: .unavailable(.noHandshake("it answered \(answer.status.rawValue)")))
            connection.cancel()
        }
    }

    private func handshakeFailed(_ run: RunState, why: String, readiness: RunState.Readiness) {
        report("xpc.handshake_failed", .warning, [.init("run", .int(run.number)), .init("reason", .string(why))])
        state.withLock { state in
            if case .starting(let starting) = state.phase, starting === run { state.phase = .idle }
        }
        _ = run.end()
        run.ready.open(readiness)
        run.settled.open(true)
    }

    private func mismatch(_ run: RunState, found: String, connection: any XPCConnection) {
        state.withLock { state in
            if state.phase.run === run { state.phase = .mismatched(expected: build, found: found) }
        }
        report("xpc.build_mismatch", .error, [
            .init("expected", .string(build), privacy: .public), .init("found", .string(found), privacy: .public),
            .init("run", .int(run.number)),
        ])
        run.noteEnd(reason: "build mismatch", byApp: true, at: ambient.clock.now)
        run.ready.open(.buildMismatch(expected: build, found: found))
        // The process is another build's: it is asked to exit, so it does not
        // live on, unused, beside the app.
        do {
            try connection.send(Outgoing<XPCEmpty>(kind: .end))
        } catch {
            // Its session has ended already: so has its process.
            return
        }
        connection.cancel()
    }

    /// The service said its run is exiting: it is ending, by its own choice.
    private func exiting(_ run: RunState) {
        let ending = state.withLock { state -> Bool in
            switch state.phase {
            case .starting(let current), .running(let current):
                guard current === run else { return false }
                state.phase = .ending(run)
                return true
            default:
                return false
            }
        }
        guard ending else { return }
        background { [self] in _ = await self.end(run, reason: "the service is exiting", byApp: false) }
    }

    /// The run is gone: the first sign of it wins, and every call still
    /// waiting on it fails.
    private func runGone(_ run: RunState) {
        guard let (failures, connection) = run.end() else { return }
        let now = ambient.clock.now
        state.withLock { state in
            if state.phase.run === run { state.phase = .idle }
            if run.info != nil { state.lastRun = (run.startedAt, now) }
        }
        for fail in failures { fail() }
        run.ready.open(.lost)
        run.settled.open(true)
        // Released cancelled: releasing a live session traps.
        connection?.cancel()
        guard let info = run.info else { return }
        let lifetime = run.startedAt.duration(to: now)
        if let reason = run.endReason {
            var fields: [Event.Field] = [
                .init("run", .int(info.number)), .init("pid", .int(Int(info.pid))), .init("reason", .string(reason)),
                .init("lifetime", .duration(lifetime)),
            ]
            if let asked = run.endAskedAt { fields.append(.init("exit_took", .duration(asked.duration(to: now)))) }
            report("xpc.run_ended", .info, fields)
        } else {
            // Lost with nothing in flight costs nothing (an idle exit looks
            // the same from here): a notice, not a warning.
            report("xpc.run_lost", failures.isEmpty ? .notice : .warning, [
                .init("run", .int(info.number)), .init("pid", .int(Int(info.pid))), .init("lifetime", .duration(lifetime)),
                .init("in_flight", .int(failures.count)),
            ])
        }
    }

    // MARK: Ending

    /// Ends the live run: asks the service to exit, waits up to the end
    /// grace for it to go, kills it if it does not (when this app may), and
    /// declares it wedged if it still does not go.
    ///
    /// Calls made meanwhile wait for the run to go, within their own
    /// deadlines, and reach a new run. The end goes on if the caller stops
    /// waiting (`.inProgress`).
    @discardableResult
    public func end(reason: String) async -> XPCEndResult {
        let (run, starting) = state.withLock { state -> (RunState?, Bool) in
            switch state.phase {
            case .starting(let run): (run, true)
            case .running(let run), .ending(let run): (run, false)
            case .idle, .wedged, .mismatched, .shutDown: (nil, false)
            }
        }
        guard let run else { return .notRunning }
        if starting {
            // A run that is starting has no process to ask yet: its handshake
            // decides first, and the calls waiting on it are not failed for it.
            guard let readiness = await run.ready.wait() else { return .inProgress }
            guard case .live = readiness else { return run.hasEnded ? .exited : .notRunning }
        }
        return await end(run, reason: reason, byApp: true)
    }

    private func end(_ run: RunState, reason: String, byApp: Bool) async -> XPCEndResult {
        let (outcome, first) = run.askToEnd(reason: reason, byApp: byApp, at: ambient.clock.now)
        if first {
            let proceeding = state.withLock { state -> Bool in
                guard let current = state.phase.run, current === run, !run.hasEnded else { return false }
                if case .wedged = state.phase { return false }
                state.phase = .ending(run)
                return true
            }
            if proceeding {
                background { [self] in outcome.open(await escalate(run)) }
            } else {
                outcome.open(run.hasEnded ? .exited : .notRunning)
            }
        }
        return await outcome.wait() ?? .inProgress
    }

    private func escalate(_ run: RunState) async -> XPCEndResult {
        do {
            try run.connection?.send(Outgoing<XPCEmpty>(kind: .end))
        } catch {
            // The session is over though its end has not been heard yet:
            // the run is gone.
            runGone(run)
            return .exited
        }
        if await gone(run, within: policy.endGrace) { return .exited }
        let killed = run.info.map(transport.terminate) ?? false
        report("xpc.end_escalated", .warning, [
            .init("run", .int(run.number)), .init("killed", .bool(killed)), .init("grace", .duration(policy.endGrace)),
        ])
        if killed, await gone(run, within: policy.killGrace) { return .killed }
        let wedged = state.withLock { state -> Bool in
            guard case .ending(let current) = state.phase, current === run else { return false }
            state.phase = .wedged(run)
            return true
        }
        guard wedged else { return killed ? .killed : .exited }
        report("xpc.run_wedged", .error, [
            .init("run", .int(run.number)), .init("pid", .int(Int(run.info?.pid ?? 0))), .init("killed", .bool(killed)),
        ])
        run.settled.open(false)
        return .wedged
    }

    private func gone(_ run: RunState, within grace: Duration) async -> Bool {
        if run.hasEnded { return true }
        let ended = await withTimeout(grace, clock: ambient.clock) {
            await run.settled.wait()
        }
        return ended != nil && run.hasEnded
    }

    // MARK: Shutting down

    /// Ends the peer: the live session is cancelled, calls waiting on it
    /// fail `.unavailable` or `.lost`, and every later call fails
    /// `.unavailable`. For an app that is quitting, and for tests.
    public func shutdown() {
        let run = state.withLock { state -> RunState? in
            let run = state.phase.run
            state.phase = .shutDown
            return run
        }
        unregister()
        guard let run else { return }
        run.noteEnd(reason: "the peer shut down", byApp: true, at: ambient.clock.now)
        run.ready.open(.unavailable(.shutDown))
        // Fails the calls waiting on the run first, then cancels its session:
        // a handler that the cancellation ends must not answer them.
        runGone(run)
    }

    // MARK: Support

    private var isShutDown: Bool {
        state.withLock { state in
            if case .shutDown = state.phase { return true }
            return false
        }
    }

    /// Runs `work` in a task the peer owns: in the context the peer was made
    /// in, and none of the calling task's (its deadline, its retry attempt).
    /// Each such task is bounded by a timeout or grace of its own.
    private func background(_ work: @escaping @Sendable () async -> Void) {
        Task.owned(in: ambient) { await work() }
    }

    func report(_ name: EventName, _ level: Event.Level, _ fields: [Event.Field]) {
        let instrumentation = ambient.instrumentation
        guard instrumentation.isEnabled(level) else { return }
        instrumentation.record(Event(name, level: level, label: service, fields: fields))
    }
}
#endif
