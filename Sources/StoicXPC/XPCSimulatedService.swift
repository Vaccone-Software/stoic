#if os(macOS)
internal import Stoic
internal import Foundation
internal import Synchronization

/// An ``XPCTransport`` that runs a real ``XPCHost`` in this process, as a
/// simulated service process: for tests of anything built on ``XPCPeer``.
///
/// Each run of the service calls `makeHost` for a fresh host, so what a
/// process held dies with it, as it would. Messages are encoded to JSON and
/// decoded on the other side (so a type that does not round-trip fails here
/// too), and delivered in order, one at a time, as a listener's queue
/// delivers them. The process behaves as the spike measured the system's
/// (design/25, Origin):
///
/// - **A session to a process that is exiting reaches it**, for the
///   ``exitLag`` the process takes to go.
/// - **Cancelling a session does not fail its pending replies.** They arrive
///   when the host answers.
/// - **A crash fails pending replies and ends sessions** in an order the
///   test chooses, with a fault point between (`xpc.loss_order`) for a
///   simulation to stretch.
/// - **A kill can be refused** (``permitsKill``), as a sandbox refuses it.
///
/// Timers — the exit lag, the host's idle exit and watchdog — run on the
/// ambient clocks of the context the service was made in, so under a
/// `TestClock` the test decides when a process exits.
///
///     let service = XPCSimulatedService { () -> XPCHost in
///         let host = XPCHost(build: "1")
///         host.handle(ModelsAPI.stats) { _, _ in ModelsStats(loaded: 0) }
///         return host
///     }
///     let peer = XPCPeer(service: "models", build: "1", transport: service)
public final class XPCSimulatedService: XPCTransport {
    private struct State {
        var current: SimulatedProcess?
        var runs = 0
        var nextPID: Int32
        var exitLag: Duration
        var launchDelay: Duration = .zero
        var permitsKill: Bool
        var refusal: String?
        var exits: [Int32] = []
        var sessions = 0
    }

    private let state: Mutex<State>
    private let makeHost: @Sendable () -> XPCHost
    let ambient: Ambient

    /// - Parameters:
    ///   - firstPID: The pid of the first process; each later one adds one.
    ///   - exitLag: How long a process takes to exit once it decides to.
    ///   - permitsKill: Whether ``XPCTransport/terminate(_:)`` may kill it.
    ///   - makeHost: Makes the host of each new process.
    public init(firstPID: Int32 = 1000, exitLag: Duration = .zero, permitsKill: Bool = true, makeHost: @escaping @Sendable () -> XPCHost) {
        state = Mutex(State(nextPID: firstPID, exitLag: exitLag, permitsKill: permitsKill))
        self.makeHost = makeHost
        self.ambient = Ambient.current
    }

    // MARK: Observing

    /// How many processes have started.
    public var runs: Int {
        state.withLock { $0.runs }
    }

    /// How many sessions have been opened, to any process.
    public var sessions: Int {
        state.withLock { $0.sessions }
    }

    /// The live process's pid, if one is running (exiting or not).
    public var pid: Int32? {
        state.withLock { state in state.current.flatMap { $0.isAlive ? $0.pid : nil } }
    }

    /// How each process ended, in order: its exit code; `-9` for a kill,
    /// `-11` for a crash.
    public var exits: [Int32] {
        state.withLock { $0.exits }
    }

    /// The live process's host, to inspect.
    public var host: XPCHost? {
        state.withLock { state in state.current.flatMap { $0.isAlive ? $0.host : nil } }
    }

    // MARK: Shaping

    /// How long a process takes to exit once it decides to.
    public var exitLag: Duration {
        get { state.withLock { $0.exitLag } }
        set { state.withLock { $0.exitLag = newValue } }
    }

    /// How long a new process takes to answer its first message: launchd's
    /// start, or its delay before restarting a service that lived under ten
    /// seconds.
    public var launchDelay: Duration {
        get { state.withLock { $0.launchDelay } }
        set { state.withLock { $0.launchDelay = newValue } }
    }

    /// Whether a kill is permitted. `false` is a sandboxed app.
    public var permitsKill: Bool {
        get { state.withLock { $0.permitsKill } }
        set { state.withLock { $0.permitsKill = newValue } }
    }

    /// When set, no session can be made, for this reason: the service is
    /// not in the bundle.
    public var refusesConnections: String? {
        get { state.withLock { $0.refusal } }
        set { state.withLock { $0.refusal = newValue } }
    }

    /// Crashes the live process now: its pending replies fail and its
    /// sessions end, in the order asked, with the fault point
    /// `xpc.loss_order` between. Returns once both have happened.
    public func crash(sessionsEndFirst: Bool = false) async {
        guard let process = state.withLock({ $0.current }) else { return }
        await process.die(code: -11, sessionsEndFirst: sessionsEndFirst)
    }

    // MARK: XPCTransport

    public func connect(onEnd: @escaping @Sendable () -> Void) throws(XPCConnectFailure) -> any XPCConnection {
        if let refusal = refusesConnections { throw XPCConnectFailure(refusal) }
        let process = liveProcess()
        let connection = SimulatedConnection(process: process, session: process.host.openSession(), onEnd: onEnd, ambient: ambient)
        state.withLock { $0.sessions += 1 }
        process.add(connection)
        return connection
    }

    public func terminate(_ run: XPCRun) -> Bool {
        let process = state.withLock { state -> SimulatedProcess? in
            guard state.permitsKill, let current = state.current, current.isAlive, current.pid == run.pid else { return nil }
            return current
        }
        guard let process else { return false }
        Task { await process.die(code: -9, sessionsEndFirst: false) }
        return true
    }

    // MARK: Processes

    /// The live process — one that is exiting included — or a new one.
    private func liveProcess() -> SimulatedProcess {
        if let current = state.withLock({ state in state.current.flatMap { $0.isAlive ? $0 : nil } }) {
            return current
        }
        let host = makeHost()
        let (process, created) = state.withLock { state -> (SimulatedProcess, Bool) in
            if let current = state.current, current.isAlive { return (current, false) }
            state.runs += 1
            defer { state.nextPID += 1 }
            let process = SimulatedProcess(pid: state.nextPID, host: host, service: self)
            state.current = process
            return (process, true)
        }
        if created {
            host.attach(HostRuntime(
                pid: process.pid,
                exit: { [weak process] code in process?.exit(code) },
                watch: { [weak process] instant in process?.watch(until: instant) }
            ))
            process.launch(after: launchDelay)
        }
        return process
    }

    fileprivate func exited(_ process: SimulatedProcess, code: Int32) {
        state.withLock { $0.exits.append(code) }
    }
}

/// One simulated service process: its host, its sessions, and the serial
/// queue its messages are delivered on.
final class SimulatedProcess: Sendable {
    let pid: Int32
    let host: XPCHost
    private weak let service: XPCSimulatedService?

    private struct State {
        var alive = true
        var exiting = false
        var connections: [SimulatedConnection] = []
        var timers: [Task<Void, Never>] = []
        var queue: [@Sendable () -> Void] = []
        var draining = false
        var launched = false
    }

    private let state = Mutex(State())

    init(pid: Int32, host: XPCHost, service: XPCSimulatedService) {
        self.pid = pid
        self.host = host
        self.service = service
    }

    var isAlive: Bool {
        state.withLock { $0.alive }
    }

    var ambient: Ambient {
        service?.ambient ?? host.ambient
    }

    func add(_ connection: SimulatedConnection) {
        let alive = state.withLock { state -> Bool in
            guard state.alive else { return false }
            state.connections.append(connection)
            return true
        }
        if !alive { connection.end(failingReplies: true) }
    }

    /// Starts answering messages after `delay`.
    func launch(after delay: Duration) {
        guard delay > .zero else {
            launched()
            return
        }
        let ambient = ambient
        Task {
            do {
                try await ambient.clock.sleep(for: delay)
            } catch {
                // Nothing cancels this task; were it cancelled, the process
                // would launch at once rather than never.
                self.launched()
                return
            }
            self.launched()
        }
    }

    private func launched() {
        state.withLock { $0.launched = true }
        startDraining()
    }

    /// Delivers `work` on the process's listener queue: in order, one at a
    /// time, once the process has launched.
    func enqueue(_ work: @escaping @Sendable () -> Void) {
        let alive = state.withLock { state -> Bool in
            guard state.alive else { return false }
            state.queue.append(work)
            return true
        }
        if alive { startDraining() }
    }

    private func startDraining() {
        let start = state.withLock { state -> Bool in
            guard state.alive, state.launched, !state.queue.isEmpty, !state.draining else { return false }
            state.draining = true
            return true
        }
        guard start else { return }
        let ambient = ambient
        Task {
            await withAmbient({ $0 = ambient }) { self.drain() }
        }
    }

    private func drain() {
        while let work = state.withLock({ state -> (@Sendable () -> Void)? in
            guard state.alive, !state.queue.isEmpty else {
                state.draining = false
                state.queue = []
                return nil
            }
            return state.queue.removeFirst()
        }) {
            work()
        }
    }

    /// The host decided to exit: the process goes after the exit lag.
    func exit(_ code: Int32) {
        let first = state.withLock { state -> Bool in
            guard state.alive, !state.exiting else { return false }
            state.exiting = true
            return true
        }
        guard first else { return }
        let lag = service?.exitLag ?? .zero
        let ambient = ambient
        Task {
            await withAmbient({ $0 = ambient }) {
                if lag > .zero {
                    do {
                        try await ambient.clock.sleep(for: lag)
                    } catch {
                        // Nothing cancels this task; were it cancelled, the
                        // process would exit at once rather than never.
                        await self.die(code: code, sessionsEndFirst: false)
                        return
                    }
                }
                await self.die(code: code, sessionsEndFirst: false)
            }
        }
    }

    /// Checks the host's watchdog by `instant` on the liveness clock.
    func watch(until instant: AnyClock.Instant) {
        let ambient = ambient
        let timer = Task {
            do {
                try await ambient.livenessClock.sleep(until: instant)
            } catch {
                return
            }
            if self.isAlive { self.host.checkWatchdog() }
        }
        let alive = state.withLock { state -> Bool in
            guard state.alive else { return false }
            state.timers.append(timer)
            return true
        }
        if !alive { timer.cancel() }
    }

    /// The process is gone: handlers stop, pending replies fail and
    /// sessions end, in the order asked.
    func die(code: Int32, sessionsEndFirst: Bool) async {
        let ended = state.withLock { state -> (connections: [SimulatedConnection], timers: [Task<Void, Never>])? in
            guard state.alive else { return nil }
            state.alive = false
            defer {
                state.connections = []
                state.timers = []
            }
            return (state.connections, state.timers)
        }
        guard let ended else { return }
        for timer in ended.timers { timer.cancel() }
        host.processEnded()
        service?.exited(self, code: code)
        if sessionsEndFirst {
            for connection in ended.connections { connection.end(failingReplies: false) }
            await FaultPoint.hit("xpc.loss_order")
            for connection in ended.connections { connection.failPendingReplies() }
        } else {
            for connection in ended.connections { connection.failPendingReplies() }
            await FaultPoint.hit("xpc.loss_order")
            for connection in ended.connections { connection.end(failingReplies: false) }
        }
    }
}

/// One simulated session.
final class SimulatedConnection: XPCConnection {
    private struct State {
        var open = true
        var ended = false
        var nextReply: UInt64 = 0
        var pending: [UInt64: @Sendable (Result<Data, XPCDeliveryFailure>) -> Void] = [:]
    }

    private let process: SimulatedProcess
    private let session: HostSession
    private let onEnd: @Sendable () -> Void
    private let ambient: Ambient
    private let state = Mutex(State())

    init(process: SimulatedProcess, session: HostSession, onEnd: @escaping @Sendable () -> Void, ambient: Ambient) {
        self.process = process
        self.session = session
        self.onEnd = onEnd
        self.ambient = ambient
    }

    func send<Message: Encodable & Sendable, Reply: Decodable & Sendable>(
        _ message: Message,
        replyHandler: @escaping @Sendable (Result<Reply, XPCDeliveryFailure>) -> Void
    ) throws(XPCDeliveryFailure) {
        let data = try Self.encode(message)
        let id = state.withLock { state -> UInt64? in
            guard state.open, process.isAlive else { return nil }
            state.nextReply += 1
            state.pending[state.nextReply] = { result in
                switch result {
                case .success(let data):
                    do {
                        replyHandler(.success(try JSONDecoder().decode(Reply.self, from: data)))
                    } catch {
                        replyHandler(.failure(.undecodable(String(describing: error))))
                    }
                case .failure(let failure):
                    replyHandler(.failure(failure))
                }
            }
            return state.nextReply
        }
        guard let id else { throw .connectionLost("the session has ended") }
        let incoming = SimulatedMessage(data: data, expectsReply: true) { [weak self] answer in self?.deliver(id, answer) }
        let session = session
        let host = process.host
        process.enqueue { host.receive(incoming, on: session) }
    }

    func send<Message: Encodable & Sendable>(_ message: Message) throws(XPCDeliveryFailure) {
        let data = try Self.encode(message)
        guard state.withLock({ $0.open }), process.isAlive else { throw .connectionLost("the session has ended") }
        let incoming = SimulatedMessage(data: data, expectsReply: false) { _ in }
        let session = session
        let host = process.host
        process.enqueue { host.receive(incoming, on: session) }
    }

    /// Cancelling ends the session at once; its pending replies are not
    /// failed, as the system's are not.
    func cancel() {
        let first = state.withLock { state -> Bool in
            guard state.open else { return false }
            state.open = false
            return true
        }
        guard first else { return }
        process.host.sessionEnded(session)
        let ambient = ambient
        Task {
            await withAmbient({ $0 = ambient }) { self.end(failingReplies: false) }
        }
    }

    private func deliver(_ id: UInt64, _ data: Data) {
        guard process.isAlive else { return }
        let handler = state.withLock { $0.pending.removeValue(forKey: id) }
        handler?(.success(data))
    }

    func failPendingReplies() {
        let pending = state.withLock { state in
            defer { state.pending = [:] }
            return Array(state.pending.values)
        }
        for handler in pending { handler(.failure(.connectionLost("the process is gone"))) }
    }

    /// Ends the session: `onEnd` runs once.
    func end(failingReplies: Bool) {
        let first = state.withLock { state -> Bool in
            state.open = false
            guard !state.ended else { return false }
            state.ended = true
            return true
        }
        if failingReplies { failPendingReplies() }
        if first { onEnd() }
    }

    private static func encode(_ message: some Encodable) throws(XPCDeliveryFailure) -> Data {
        do {
            return try JSONEncoder().encode(message)
        } catch {
            throw .undecodable(String(describing: error))
        }
    }
}

/// A message on a simulated session.
struct SimulatedMessage: HostMessage {
    let data: Data
    let expectsReply: Bool
    let answer: @Sendable (Data) -> Void

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    func reply(_ answer: some Encodable & Sendable) {
        guard expectsReply else { return }
        do {
            self.answer(try JSONEncoder().encode(answer))
        } catch {
            // A reply that does not encode is the handler's bug: the caller
            // is told so, rather than left to time out.
            let refusal = Answer<XPCEmpty, XPCEmpty>(status: .undecodable, detail: "the reply did not encode: \(error)")
            do {
                self.answer(try JSONEncoder().encode(refusal))
            } catch {
                return
            }
        }
    }
}
#endif
