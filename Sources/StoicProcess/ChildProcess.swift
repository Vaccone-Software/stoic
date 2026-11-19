#if os(macOS)
internal import Stoic
internal import Darwin
internal import Dispatch
internal import Synchronization

/// How a child process ended.
public enum ProcessExit: Sendable, Hashable, CustomStringConvertible {
    /// It exited with this status.
    case exited(Int32)
    /// A signal ended it.
    case signalled(Int32)
    /// Something else in this process reaped it first (`SIGCHLD` set to be
    /// ignored, or a `waitpid(-1)` elsewhere), so how it ended is not known.
    case vanished

    /// Exited with status 0.
    public var succeeded: Bool { self == .exited(0) }

    /// The status a shell would report: the exit status, or 128 plus the
    /// signal.
    public var status: Int32 {
        switch self {
        case .exited(let code): code
        case .signalled(let signal): 128 + signal
        case .vanished: -1
        }
    }

    public var description: String {
        switch self {
        case .exited(let code): "exit \(code)"
        case .signalled(let signal): "signal \(signal)"
        case .vanished: "reaped elsewhere"
        }
    }
}

/// A program this process started, and everything it starts in turn.
///
/// Start one with ``start(_:options:)`` and keep the handle for as long as
/// the child should run: an owned child (``Command/Lifetime/owned``) is
/// stopped, with its whole process group, when the handle is released
/// while it runs (`process.abandoned`), so a child never outlives what
/// started it by being forgotten. For a program run to its end, use
/// ``run(_:timeout:keepingLast:options:onOutput:)``.
///
/// Its standard output and error, when they are pipes, are read through
/// ``output`` and ``errors`` (as they are asked for; see ``ProcessOutput``),
/// and its input written through ``input``. ``waitForExit()`` returns how it
/// ended. The output's end and the exit are separate, and in order for a
/// reader that reads the output to its end and then waits for the exit: it
/// has every line before it learns the child ended.
///
/// ``stop(grace:)`` ends it: `SIGTERM` to its process group and to any
/// descendant that left the group, `SIGKILL` to whatever is still running
/// after the grace. The stop is shielded (cancelling the caller does not cut
/// it short) and bounded (grace, then ``Options/killWait``), and every signal
/// is sent only to a process that is still the one started: a pid that has
/// been reused is never signalled.
public final class ChildProcess: Sendable, CustomStringConvertible {
    /// How a child is read, written and stopped.
    public struct Options: Sendable {
        /// Names the child in events. The program's name when nil.
        public var label: String?
        /// How long the output may stay open once the child has ended:
        /// longer means a program it left running in the background holds
        /// it (see ``ProcessOutput``).
        public var drainGrace: Duration
        /// How long a stop waits after `SIGTERM` before `SIGKILL`.
        public var stopGrace: Duration
        /// How long a stop waits, after `SIGKILL`, for the child to be
        /// reaped. A process in uninterruptible I/O (a dead network volume)
        /// can outlast it: `process.unkillable` says so.
        public var killWait: Duration
        /// The most input that may be queued and not yet written.
        public var inputCapacity: Int
        /// Where the child is recorded while it runs, so the next launch of
        /// this program can stop it if this one crashes. Owned children only.
        public var ledger: ProcessLedger?

        public init(
            label: String? = nil,
            drainGrace: Duration = .seconds(2),
            stopGrace: Duration = .seconds(3),
            killWait: Duration = .seconds(5),
            inputCapacity: Int = 64 * 1024 * 1024,
            ledger: ProcessLedger? = nil
        ) {
            self.label = label
            self.drainGrace = drainGrace
            self.stopGrace = stopGrace
            self.killWait = killWait
            self.inputCapacity = inputCapacity
            self.ledger = ledger
        }
    }

    let core: Core

    /// The child's pid. Its process group has the same number.
    public var pid: Int32 { core.identity.pid }

    /// Its standard output, when that is a pipe.
    public let output: ProcessOutput?
    /// Its standard error, when that is a pipe of its own.
    public let errors: ProcessOutput?
    /// Its standard input, when that is a pipe.
    public let input: ProcessInput?

    /// How it ended, once it has.
    public var exit: ProcessExit? { core.exit }

    /// Whether it is still running (or ended and not yet reaped).
    public var isRunning: Bool { core.exit == nil }

    /// Starts `command`.
    ///
    /// - Throws: ``ProcessError/couldNotStart(executable:errno:)`` when the
    ///   program cannot be run, ``ProcessError/couldNotPrepare(what:errno:)``
    ///   when a pipe cannot be made, and ``ProcessError/pipeForDetached`` for
    ///   a detached command with a pipe. Nothing is left running or open.
    public static func start(_ command: Command, options: Options = Options()) throws(ProcessError) -> ChildProcess {
        let label = options.label ?? command.executable.split(separator: "/").last.map(String.init) ?? command.executable
        let spawned: (pid: Int32, pipes: SpawnedPipes)
        do {
            spawned = try Spawn.start(command)
        } catch {
            Recorder().record(Event("process.spawn_failed", level: .warning, label: label,
                                 fields: [.init("reason", .string(error.description), privacy: .public)]))
            throw error
        }
        return ChildProcess(command: command, options: options, label: label, pid: spawned.pid, pipes: spawned.pipes)
    }

    private init(command: Command, options: Options, label: String, pid: Int32, pipes: SpawnedPipes) {
        let queue = ChildProcess.queue
        let recorder = Recorder()
        output = pipes.output.map {
            ProcessOutput(reader: Reader(Descriptor($0, .read, queue: queue), label: label, stream: "output", recorder: recorder))
        }
        errors = pipes.errors.map {
            ProcessOutput(reader: Reader(Descriptor($0, .read, queue: queue), label: label, stream: "errors", recorder: recorder))
        }
        input = pipes.input.map {
            ProcessInput(Descriptor($0, .write, queue: queue), capacity: options.inputCapacity, label: label, recorder: recorder)
        }
        // The kernel knows the child from the moment posix_spawn returns;
        // it cannot have been reaped yet, since only this process can.
        let identity = ProcessIdentity.of(pid) ?? ProcessIdentity(pid: pid, started: 0)
        core = Core(identity: identity, label: label, lifetime: command.lifetime, options: options,
                    readers: [output?.reader, errors?.reader].compactMap(\.self), input: input, recorder: recorder)
        if command.lifetime == .owned { options.ledger?.record(identity, label: label, recorder: recorder) }
        recorder.record(Event("process.started", level: .debug, label: label, fields: [
            .init("pid", .int(Int(pid))),
            .init("program", .string(command.description), privacy: .public),
        ]))
        core.watchExit()
    }

    deinit {
        guard core.lifetime == .owned, core.exit == nil else { return }
        core.recorder.record(Event("process.abandoned", level: .warning, label: core.label,
                             fields: [.init("pid", .int(Int(core.identity.pid)))]))
        core.beginStop(grace: core.options.stopGrace)
    }

    /// Returns how the child ended, once it has.
    ///
    /// - Throws: `CancellationError` if the task is cancelled first. The
    ///   child is not stopped by that: stop it, or let the handle go.
    public func waitForExit() async throws(CancellationError) -> ProcessExit {
        try await core.waitForExit()
    }

    /// Stops the child and everything it started, and returns how it ended:
    /// nil only when even `SIGKILL` had not ended it within ``Options/killWait``.
    ///
    /// Shielded: it runs to its end however the caller is cancelled. Calls
    /// made while a stop is under way wait for that one.
    @discardableResult
    public func stop(grace: Duration? = nil) async -> ProcessExit? {
        await core.stop(grace: grace ?? core.options.stopGrace)
    }

    /// Begins ``stop(grace:)`` and returns at once: for a cancellation
    /// handler, a `deinit`, or anything else that cannot wait. The `SIGTERM`
    /// has been sent when it returns, so an app that exits straight after
    /// (`applicationWillTerminate`) has still asked its children to go; the
    /// `SIGKILL` after the grace needs the app to still be running, and
    /// what it would have killed a ``ProcessLedger`` finds at the next launch.
    public func terminate(grace: Duration? = nil) {
        core.beginStop(grace: grace ?? core.options.stopGrace)
    }

    /// Sends `signal` to the child's process group while the child is
    /// still the one started (nothing once it has been reaped).
    public func signal(_ signal: Int32) {
        core.signalGroup(signal)
    }

    public var description: String { "ChildProcess(\(core.label), pid \(core.identity.pid))" }

    /// One queue for every child's exit source, readiness sources and
    /// signals: reaping and signalling are serialised, so a signal is never
    /// sent by pid after the reap that frees it.
    static let queue = DispatchQueue(label: "stoic.process")
}

/// What a child's handle shares with the tasks that watch it, so that they
/// do not keep the handle (and the child) alive.
final class Core: Sendable {
    let identity: ProcessIdentity
    let label: String
    let lifetime: Command.Lifetime
    let options: ChildProcess.Options
    let readers: [Reader]
    let input: ProcessInput?
    let recorder: Recorder
    private let started: AnyClock.Instant
    private let state = Mutex(State())

    private struct State {
        var exit: ProcessExit?
        var source: (any DispatchSourceProcess)?
        var waiters: [(id: Int, waiter: CheckedContinuation<ProcessExit?, Never>)] = []
        var nextWaiter = 0
        var stopping: Task<ProcessExit?, Never>?
        var resumed = false
    }

    init(identity: ProcessIdentity, label: String, lifetime: Command.Lifetime, options: ChildProcess.Options,
         readers: [Reader], input: ProcessInput?, recorder: Recorder) {
        self.identity = identity
        self.label = label
        self.lifetime = lifetime
        self.options = options
        self.readers = readers
        self.input = input
        self.recorder = recorder
        started = recorder.clock.now
    }

    var exit: ProcessExit? { state.withLock { $0.exit } }

    // MARK: Exit

    func watchExit() {
        let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: .exit, queue: ChildProcess.queue)
        state.withLock { $0.source = source }
        source.setEventHandler { [self] in reap() }
        // Registering for the exit of a process that has already exited
        // reports nothing, and activation registers later, on Dispatch's own
        // time. So the child was started suspended, and is let go only once
        // the watch is in place: from then on its exit is an event.
        source.setRegistrationHandler { [self] in resume() }
        source.activate()
        // Every wait has an end: should the watch still not have been
        // registered, or its event be lost, the child is let go and looked
        // at again every so often until it has been reaped.
        let recorder = recorder
        Task { [self] in
            while exit == nil {
                await recorder.pause(for: .seconds(2))
                await onQueue { [self] in
                    resume()
                    reap()
                }
            }
        }
    }

    /// On the queue: lets a suspended child run (once).
    private func resume() {
        let first = state.withLock { state -> Bool in
            defer { state.resumed = true }
            return !state.resumed
        }
        guard first, exit == nil else { return }
        _ = kill(identity.pid, SIGCONT)
        reap()
    }

    /// On the queue: reaps the child if it has ended.
    private func reap() {
        guard exit == nil else { return }
        var status: Int32 = 0
        let result = unsafe waitpid(identity.pid, &status, WNOHANG)
        let ended: ProcessExit
        if result == identity.pid {
            ended = ProcessExit(waitStatus: status)
        } else if result < 0, errno == ECHILD {
            ended = .vanished
        } else {
            return
        }
        let (source, waiters) = state.withLock { state -> ((any DispatchSourceProcess)?, [CheckedContinuation<ProcessExit?, Never>]) in
            state.exit = ended
            defer {
                state.source = nil
                state.waiters = []
            }
            return (state.source, state.waiters.map(\.waiter))
        }
        source?.cancel()
        if lifetime == .owned { options.ledger?.forget(identity, recorder: recorder) }
        recorder.record(Event("process.exited", level: ended.succeeded ? .debug : .info, label: label, fields: [
            .init("pid", .int(Int(identity.pid))),
            .init("exit", .string(ended.description), privacy: .public),
            .init("ran", .duration(started.duration(to: recorder.clock.now))),
        ]))
        // Nothing can read the input now: closed before anyone hears of the
        // exit, so a send made after it is refused, never queued for no one.
        input?.close()
        for waiter in waiters { waiter.resume(returning: ended) }
        // The output is read to its end, or for the grace while something
        // the child left behind holds it.
        guard !readers.isEmpty else { return }
        let readers = readers
        let grace = options.drainGrace
        let recorder = recorder
        Task {
            await recorder.pause(for: grace)
            for reader in readers { reader.endWhenIdle() }
        }
    }

    func waitForExit() async throws(CancellationError) -> ProcessExit {
        guard let exit = await waitForExit(cancellable: true) else { throw CancellationError() }
        return exit
    }

    /// Nil when cancelled.
    private func waitForExit(cancellable: Bool) async -> ProcessExit? {
        let id = state.withLock { state -> Int in
            defer { state.nextWaiter += 1 }
            return state.nextWaiter
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<ProcessExit?, Never>) in
                let now = state.withLock { state -> (ProcessExit?, Bool) in
                    if let exit = state.exit { return (exit, true) }
                    if cancellable, Task.isCancelled { return (nil, true) }
                    state.waiters.append((id, waiter))
                    return (nil, false)
                }
                if now.1 { waiter.resume(returning: now.0) }
            }
        } onCancel: {
            guard cancellable else { return }
            state.withLock { state -> CheckedContinuation<ProcessExit?, Never>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index).waiter
            }?.resume(returning: nil)
        }
    }

    /// The exit, or nil if `limit` passes first.
    ///
    /// Only ever called from a stop's own task, which nothing cancels (that
    /// is its shield), so both sides of the race may be cancellable: the
    /// race cancels the loser, and waits for it to go.
    private func exit(within limit: Duration) async -> ProcessExit? {
        if let exit { return exit }
        let clock = recorder.clock
        return await race(
            { [self] in await waitForExit(cancellable: true) },
            { () async -> ProcessExit? in
                do { try await clock.sleep(until: clock.now.advanced(by: limit), tolerance: nil) } catch { return nil }
                return nil
            })
    }

    // MARK: Stop

    func beginStop(grace: Duration) {
        _ = stopTask(grace: grace)
    }

    func stop(grace: Duration) async -> ProcessExit? {
        await stopTask(grace: grace).value
    }

    /// One stop at a time: a second call joins the first.
    ///
    /// The `SIGTERM` is sent before this returns, whoever calls it: a stop
    /// begun as the app quits (`applicationWillTerminate`, a `deinit`) must
    /// not depend on a task the app may never run. Only the wait, and the
    /// `SIGKILL` after it, are the task's.
    private func stopTask(grace: Duration) -> Task<ProcessExit?, Never> {
        if let stopping = state.withLock({ $0.stopping }) { return stopping }
        // Not under the state's lock: the queue's reap takes it.
        let strays = ChildProcess.queue.sync { [self] in
            // Who is ours, found while the child is alive to be asked: once
            // it ends, its children are adopted by launchd and can no longer
            // be found from it.
            let strays = exit == nil ? ProcessTable.descendants(of: identity.pid) : []
            signalGroupOnQueue(SIGTERM)
            return strays
        }
        for stray in strays { stray.signal(SIGTERM) }
        return state.withLock { state in
            if let stopping = state.stopping { return stopping }
            // Unstructured, so that the caller's cancellation does not reach
            // it: awaiting its value is the shield.
            let stopping = Task { [self] in await escalate(strays, grace: grace) }
            state.stopping = stopping
            return stopping
        }
    }

    /// After the `SIGTERM`: the wait, and the `SIGKILL` to whatever is left.
    private func escalate(_ strays: [ProcessIdentity], grace: Duration) async -> ProcessExit? {
        let start = recorder.clock.now
        var ended = await exit(within: grace)
        // The group may outlive its leader: the dev server a shell started.
        while ended != nil, !survivors(strays).isEmpty, start.duration(to: recorder.clock.now) < grace {
            await recorder.pause(for: .milliseconds(50))
        }

        let left = survivors(strays)
        if ended == nil || !left.isEmpty {
            recorder.record(Event("process.stop_escalated", level: .warning, label: label, fields: [
                .init("pid", .int(Int(identity.pid))),
                .init("leader_ended", .bool(ended != nil)),
                .init("survivors", .int(left.count)),
            ]))
            await onQueue { [self] in signalGroupOnQueue(SIGKILL) }
            for stray in left { stray.signal(SIGKILL) }
        }
        if ended == nil { ended = await exit(within: options.killWait) }
        if ended == nil {
            recorder.record(Event("process.unkillable", level: .error, label: label,
                                 fields: [.init("pid", .int(Int(identity.pid)))]))
        }
        state.withLock { $0.stopping = nil }
        return ended
    }

    /// The group's members still running, and the strays found outside it.
    private func survivors(_ strays: [ProcessIdentity]) -> [ProcessIdentity] {
        guard lifetime == .owned else { return strays.filter(\.isAlive) }
        let members = ProcessTable.group(ledBy: identity).filter { $0 != identity }
        return members + strays.filter { $0.isAlive && !members.contains($0) }
    }

    /// For a caller that cannot wait: the work on the queue is a few
    /// system calls, and the queue never waits on a task.
    func signalGroup(_ signal: Int32) {
        ChildProcess.queue.sync { signalGroupOnQueue(signal) }
    }

    /// On the queue, so never after the reap: while the child is unreaped
    /// its pid (and so its group's number) is held and cannot be reused;
    /// after it, only members that started since the child did are
    /// signalled, each checked.
    private func signalGroupOnQueue(_ signal: Int32) {
        dispatchPrecondition(condition: .onQueue(ChildProcess.queue))
        guard lifetime == .owned else {
            if exit == nil { _ = kill(identity.pid, signal) }
            return
        }
        if exit == nil {
            _ = kill(-identity.pid, signal)
        } else {
            for member in ProcessTable.group(ledBy: identity) {
                member.signal(signal)
            }
        }
    }

    /// Runs `body` on the queue and returns its result, suspending (never
    /// blocking a thread of the pool) until it has.
    private func onQueue<R: Sendable>(_ body: @escaping @Sendable () -> R) async -> R {
        await withCheckedContinuation { (done: CheckedContinuation<R, Never>) in
            ChildProcess.queue.async { done.resume(returning: body()) }
        }
    }
}
#endif
