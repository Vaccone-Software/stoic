internal import Synchronization
public import Observation

/// What a state machine does with an event.
public enum Transition<State: Hashable & Sendable, Event: Sendable>: Sendable {
    /// Move to `state` (or re-enter the current one), optionally with a timeout.
    case to(State, timeout: StateTimeout<Event>? = nil)
    /// Stay in the current state without re-entering it: its work keeps running.
    case stay
    /// The event means nothing in this state; drop it quietly.
    case ignore
    /// The event should never arrive in this state: a bug somewhere. Reported
    /// at error level (`statemachine.invalid`); the machine stays put.
    case invalid(String)
}

/// An event a state sends itself if it is still current after `after`.
public struct StateTimeout<Event: Sendable>: Sendable {
    public let after: Duration
    public let event: Event

    public init(after: Duration, send event: Event) {
        self.after = after
        self.event = event
    }
}

/// A finite state machine whose work belongs to its states.
///
/// The transition function is plain Swift — a `switch` over state and event
/// that the compiler checks for exhaustiveness — and pure, so it can be
/// explored and tested without running anything (see ``StateGraph``).
///
///     enum Phase: Hashable, Sendable { case idle, listening, transcribing, failed }
///     enum Input: Sendable { case start, heard, finished, error, timeout, cancel }
///
///     let dictation = StateMachine<Phase, Input>(initial: .idle, label: "dictation") { phase, input in
///         switch (phase, input) {
///         case (.idle, .start): .to(.listening, timeout: .init(after: .seconds(13), send: .timeout))
///         case (.listening, .heard): .to(.transcribing)
///         case (.listening, .timeout), (_, .error): .to(.failed)
///         case (.transcribing, .finished), (_, .cancel): .to(.idle)
///         default: .ignore
///         }
///     }
///
/// **Work belongs to a state.** ``whileIn(_:label:shutdownTimeout:_:)``
/// registers work that starts each time the machine enters a matching state
/// and is cancelled (``CancellationCause/stateExited``) the moment it leaves.
/// The next visit's work starts only once the old visit's work has finished
/// — its cleanup included — or been abandoned after its `shutdownTimeout`, so
/// the two never overlap. Events that work sends back are delivered only
/// while the machine is still in the *same visit* to that state; a late event
/// from an earlier visit is dropped and reported (`statemachine.stale_event`).
/// This is the structured replacement for phase booleans and the generation
/// counters that guard them.
///
///     dictation.whileIn(.listening, label: "microphone") { sender in
///         for await level in microphone.levels() where level > threshold {
///             sender.send(.heard)
///         }
///     }
///
/// The work gets everything it needs from its ``Sender``: it need not, and
/// should not, capture the machine, which holds the work and would never be
/// freed. ``shutdown()`` ends the machine and waits for its work.
///
/// **States can time out.** A transition may carry a ``StateTimeout``: if the
/// machine is still in that visit when the time is up, it sends itself the
/// event. Leaving the state cancels the timer.
///
/// **Thread-safe and observable.** Events may be sent from any task; they are
/// applied one at a time, in order. ``states()`` streams the current state,
/// for a UI to follow.
public final class StateMachine<State: Hashable & Sendable, Event: Sendable>: Sendable, Observable {
    public typealias TransitionFunction = @Sendable (State, Event) -> Transition<State, Event>

    /// Names the machine in events.
    public let label: String

    /// How many transitions ``history`` keeps.
    public let historyLimit: Int

    /// One recorded transition.
    public struct Record: Sendable, CustomStringConvertible {
        public let from: State
        public let event: Event
        public let to: State
        public let at: AnyClock.Instant

        public var description: String { "\(from) --\(event)--> \(to) at \(at)" }
    }

    /// Delivers events from a state's work, but only during the visit that
    /// started it.
    public struct Sender: Sendable {
        let deliver: @Sendable (Event) -> Void

        /// Sends `event` if the machine is still in the visit this work
        /// belongs to; otherwise drops it (`statemachine.stale_event`).
        public func send(_ event: Event) {
            deliver(event)
        }
    }

    private struct Activity: Sendable {
        let label: String
        // The state it was registered for, or nil for a predicate.
        let state: State?
        let shutdownTimeout: Duration
        let matches: @Sendable (State) -> Bool
        let work: @Sendable (Sender) async -> Void
    }

    /// One visit's running work, how long it may take to stop, and the
    /// scopes it was started in, which count it if it is abandoned.
    private struct Running: Sendable {
        let task: Task<Void, Never>
        let label: String
        let shutdownTimeout: Duration
        let watch: AbandonmentWatch?
    }

    private struct Core {
        var state: State
        var visit: UInt64 = 0
        // A ring once full: `historyHead` is the oldest record's index.
        var history: [Record] = []
        var historyHead = 0
        var stateWork: [Running] = []
        var timer: Task<Void, Never>?
        // Ends once the work of every earlier visit has stopped or been
        // abandoned: a new visit's work waits for it before it begins.
        var exit: Task<Void, Never>?
        var isShutDown = false
        var activities: [Activity] = []
        var observers: [UInt64: AsyncStream<State>.Continuation] = [:]
        var nextObserver: UInt64 = 0
    }

    private let transition: TransitionFunction
    private let clock: AnyClock
    private let core: Mutex<Core>
    private let registrar = ObservationRegistrar()
    // Built once: a key path into a generic class is otherwise rebuilt at run
    // time, demangling its generic arguments, every time its literal is
    // evaluated — most of what a transition cost.
    private let stateKeyPath: any KeyPath<StateMachine, State> & Sendable = \.state
    private let historyKeyPath: any KeyPath<StateMachine, [Record]> & Sendable = \.history

    public init(
        initial: State,
        label: String,
        historyLimit: Int = 64,
        clock: AnyClock? = nil,
        transition: @escaping TransitionFunction
    ) {
        self.label = label
        precondition(historyLimit >= 0, "StateMachine \(label): historyLimit must not be negative")
        self.historyLimit = historyLimit
        self.transition = transition
        self.clock = clock ?? Ambient.current.clock
        self.core = Mutex(Core(state: initial))
    }

    deinit {
        let (work, observers) = core.withLock { core in
            (core.stateWork.map { $0.task } + [core.timer].compactMap { $0 }, core.observers.valuesInKeyOrder)
        }
        for task in work { task.cancel() }
        for observer in observers { observer.finish() }
    }

    /// The current state.
    ///
    /// Observable: a SwiftUI view (or anything using Observation) that reads
    /// it is updated after every transition.
    public var state: State {
        checkNotInTransition()
        registrar.access(self, keyPath: stateKeyPath)
        return core.withLock { $0.state }
    }

    /// The most recent transitions, oldest first, for diagnostics.
    public var history: [Record] {
        checkNotInTransition()
        registrar.access(self, keyPath: historyKeyPath)
        return core.withLock { core in
            Array(core.history[core.historyHead...] + core.history[..<core.historyHead])
        }
    }

    /// Handles `event`: computes the transition and applies it.
    ///
    /// Sent from this machine's own state work, the event is checked like
    /// one sent through the work's ``Sender``: once the work's visit has
    /// ended, it is dropped (`statemachine.stale_event`).
    public func send(_ event: Event) {
        checkNotInTransition()
        let visit = MachineContext.stateWork.flatMap { $0.machine == ObjectIdentifier(self) ? $0.visit : nil }
        apply(event, onlyDuring: visit)
    }

    /// Runs `work` whenever the machine is in a state matching `predicate`,
    /// and cancels it when the machine leaves that state. If the machine is
    /// already in a matching state, the work starts now.
    ///
    /// Registration is setup, done once, where the machine is made: work
    /// registered again under a label it already has (for the same state, or
    /// as a predicate) is reported at error level
    /// (`statemachine.duplicate_work`) and ignored, so a view that registers
    /// on every appearance cannot start its work twice per visit.
    ///
    /// - Parameters:
    ///   - predicate: Which states the work runs in. It runs under the
    ///     machine's lock, so it must not call back into the machine.
    ///   - label: Names the work in events and diagnostics.
    ///   - shutdownTimeout: How long the work may take to stop once its visit
    ///     ends. The next visit's work waits for it that long at most; then
    ///     it is abandoned and reported (`statemachine.work_abandoned`).
    ///   - work: Sends its events through the ``Sender`` it is given.
    public func whileIn(
        where predicate: @escaping @Sendable (State) -> Bool,
        label: String,
        shutdownTimeout: Duration = .seconds(5),
        _ work: @escaping @Sendable (Sender) async -> Void
    ) {
        register(Activity(label: label, state: nil, shutdownTimeout: shutdownTimeout, matches: predicate, work: work))
    }

    /// Runs `work` whenever the machine is in `state`; cancels it when the
    /// machine leaves.
    public func whileIn(
        _ state: State,
        label: String,
        shutdownTimeout: Duration = .seconds(5),
        _ work: @escaping @Sendable (Sender) async -> Void
    ) {
        register(Activity(label: label, state: state, shutdownTimeout: shutdownTimeout, matches: { $0 == state }, work: work))
    }

    private func register(_ activity: Activity) {
        checkNotInTransition()
        let registered = core.withLock { core -> Bool in
            guard !core.activities.contains(where: { $0.label == activity.label && $0.state == activity.state }) else { return false }
            core.activities.append(activity)
            if !core.isShutDown, Self.inTransition({ activity.matches(core.state) }) {
                core.stateWork.append(start(activity, visit: core.visit, after: core.exit))
            }
            return true
        }
        if !registered {
            Ambient.record(Stoic.Event("statemachine.duplicate_work", level: .error, label: label, fields: [
                .init("work", .string(activity.label), privacy: .public),
                .init("state", .string(activity.state.map { "\($0)" } ?? "(predicate)"), privacy: .public),
            ]))
        }
    }

    /// Ends the machine: cancels its work and timer and waits for the work to
    /// stop, each piece for at most its `shutdownTimeout` before it is
    /// abandoned. Observers' streams finish, and every later event is
    /// dropped (`statemachine.stale_event`).
    ///
    /// Call it where the machine's owner ends — a view model's teardown, a
    /// service's stop — so no state work outlives it.
    public func shutdown() async {
        checkNotInTransition()
        let (leaving, exit, observers) = core.withLock { core in
            let leaving = core.isShutDown ? [] : leave(&core)
            core.isShutDown = true
            let observers = core.observers.valuesInKeyOrder
            core.observers.removeAll()
            return (leaving, core.exit, observers)
        }
        for task in leaving { task.cancel() }
        for observer in observers { observer.finish() }
        await exit?.value
    }

    /// The machine's states as they change, starting with the current one.
    /// Buffers only the newest: an observer sees where the machine is, not
    /// every step it took to get there.
    public func states() -> AsyncStream<State> {
        checkNotInTransition()
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = core.withLock { core -> UInt64? in
            continuation.yield(core.state)
            if core.isShutDown { return nil }
            defer { core.nextObserver += 1 }
            core.observers[core.nextObserver] = continuation
            return core.nextObserver
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        // An observer that stops listening is forgotten, so views that
        // subscribe on every appearance cannot slow every transition down.
        continuation.onTermination = { [weak self] _ in
            self?.core.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    /// How many `states()` streams are still being listened to.
    var observerCount: Int {
        core.withLock { $0.observers.count }
    }

    // MARK: Internals

    private enum Outcome {
        case none
        case invalid(State, String)
        case stale
        case moved(Record)
    }

    /// Runs one of the caller's closures that the machine calls under its lock.
    private static func inTransition<R>(_ body: () -> R) -> R {
        MachineContext.$transitioning.withValue(true, operation: body)
    }

    /// A transition function or predicate that used a machine would take a
    /// lock its own thread already holds: a precondition failure that says
    /// so, rather than the lock's own abort.
    private func checkNotInTransition() {
        precondition(
            !MachineContext.transitioning,
            "StateMachine \(label): a transition function or whileIn predicate must not use a state machine (send, state, history, whileIn, states): it runs while the machine is locked. Return a Transition instead."
        )
    }

    private func apply(_ event: Event, onlyDuring visit: UInt64?) {
        var leaving: [Task<Void, Never>] = []
        let outcome = core.withLock { core -> Outcome in
            if core.isShutDown { return .stale }
            if let visit, core.visit != visit { return .stale }
            switch Self.inTransition({ transition(core.state, event) }) {
            case .stay, .ignore:
                return .none
            case .invalid(let reason):
                return .invalid(core.state, reason)
            case .to(let next, let timeout):
                if !core.stateWork.isEmpty || core.timer != nil { leaving = leave(&core) }
                return .moved(enter(next, timeout: timeout, cause: event, core: &core))
            }
        }
        // The old visit's work is cancelled after the lock is released:
        // cancellation runs the work's cancellation handlers on this thread,
        // at once, and one that touches the machine must not find it locked.
        for task in leaving { task.cancel() }
        // Observers and events are notified outside the lock: neither an
        // observation callback nor an instrumentation sink may be able to
        // deadlock the machine.
        if case .moved = outcome {
            registrar.withMutation(of: self, keyPath: stateKeyPath) {}
            registrar.withMutation(of: self, keyPath: historyKeyPath) {}
        }
        switch outcome {
        case .none:
            break
        case .stale:
            Ambient.record(Stoic.Event("statemachine.stale_event", level: .info, label: label, fields: [
                .init("event", .string("\(event)"), privacy: .public),
            ]))
        case .invalid(let state, let reason):
            Ambient.record(Stoic.Event("statemachine.invalid", level: .error, label: label, fields: [
                .init("state", .string("\(state)"), privacy: .public),
                .init("event", .string("\(event)"), privacy: .public),
                .init("reason", .string(reason), privacy: .public),
            ]))
        case .moved(let record):
            Ambient.record(level: .debug) {
                Stoic.Event("statemachine.transition", level: .debug, label: label, fields: [
                    .init("from", .string("\(record.from)"), privacy: .public),
                    .init("event", .string("\(record.event)"), privacy: .public),
                    .init("to", .string("\(record.to)"), privacy: .public),
                ])
            }
        }
    }

    /// Ends the current visit's work: returns its tasks, for the caller to
    /// cancel once the lock is released, and makes the next visit's work wait
    /// until they have stopped or been abandoned.
    private func leave(_ core: inout Core) -> [Task<Void, Never>] {
        var leaving: [Task<Void, Never>] = []
        if let timer = core.timer {
            leaving.append(timer)
            core.timer = nil
        }
        guard !core.stateWork.isEmpty else { return leaving }
        let running = core.stateWork
        core.stateWork.removeAll(keepingCapacity: true)
        for work in running { leaving.append(work.task) }
        let previous = core.exit
        let clock = clock
        let label = label
        // Each piece's time to stop counts from the moment its visit ended.
        let leftAt = clock.now
        core.exit = Task.stoic {
            await previous?.value
            await Self.awaitStop(of: running, leftAt: leftAt, clock: clock, machine: label)
        }
        return leaving
    }

    /// Waits for each piece of a visit's work to stop, abandoning one that
    /// overruns its `shutdownTimeout`: listed in `AbandonedWork` until it
    /// ends, reported, and not waited for.
    private static func awaitStop(of running: [Running], leftAt: AnyClock.Instant, clock: AnyClock, machine: String) async {
        for work in running {
            let deadline = leftAt.advanced(by: work.shutdownTimeout)
            let allowed = max(.zero, clock.now.duration(to: deadline))
            guard case .timedOut = await waitForTask(work.task, within: allowed, clock: clock) else { continue }
            let ledger = AbandonedWork.ledger
            let id = ledger.admit(label: "state machine \(machine) work \(work.label)")
            _ = ledger.abandon(id, deadline: deadline, clock: clock, watch: work.watch)
            Ambient.record(Stoic.Event("statemachine.work_abandoned", level: .error, label: machine, fields: [
                .init("work", .string(work.label), privacy: .public),
                .init("timeout", .duration(work.shutdownTimeout)),
            ]))
            Task.stoic {
                await work.task.value
                if let lateness = ledger.finish(id) {
                    Ambient.record(Stoic.Event("abandoned.completed", level: .notice, label: machine, fields: [
                        .init("work", .string(work.label), privacy: .public),
                        .init("late_by", .duration(lateness)),
                    ]))
                }
            }
        }
    }

    /// Moves to `next`, after ``leave(_:)``, and starts the new visit's work.
    private func enter(_ next: State, timeout: StateTimeout<Event>?, cause event: Event, core: inout Core) -> Record {
        let record = Record(from: core.state, event: event, to: next, at: clock.now)
        core.visit += 1
        core.state = next
        if core.history.count < historyLimit {
            core.history.append(record)
        } else if historyLimit > 0 {
            core.history[core.historyHead] = record
            core.historyHead = (core.historyHead + 1) % historyLimit
        }
        if !core.observers.isEmpty {
            for observer in core.observers.valuesInKeyOrder { observer.yield(next) }
        }

        // Enter: start the new visit's work and its timer.
        let visit = core.visit
        for activity in core.activities where Self.inTransition({ activity.matches(next) }) {
            core.stateWork.append(start(activity, visit: visit, after: core.exit))
        }
        if let timeout {
            let clock = clock
            // The timer's instant is fixed at entry, not when its task first
            // runs: advancing a test clock right after a transition must fire it.
            let fireAt = clock.now.advanced(by: timeout.after)
            let sender = makeSender(visit: visit)
            core.timer = TaskLedger.task(.stateTimeout, label: label) {
                do {
                    try await clock.sleep(until: fireAt, tolerance: nil)
                } catch {
                    return
                }
                sender.send(timeout.event)
            }
        }
        return record
    }

    private func start(_ activity: Activity, visit: UInt64, after previous: Task<Void, Never>?) -> Running {
        let cause = CancellationCauseBox(parent: nil)
        let sender = makeSender(visit: visit)
        let work = activity.work
        let context = MachineContext.StateWork(machine: ObjectIdentifier(self), visit: visit)
        let task = TaskLedger.task(.stateWork, label: "\(label).\(activity.label)") {
            // State work belongs to the state, not to whoever sent the event
            // that entered it: it does not inherit the sender's deadline.
            await Deadline.$stored.withValue(nil) {
                await CancellationCauseBox.$current.withValue(cause) {
                    // The earlier visits' work has stopped, or been
                    // abandoned, before this visit's begins; a visit left
                    // before then runs none.
                    await previous?.value
                    guard !Task.isCancelled else { return }
                    // Late-starting work meets events from a later visit.
                    await FaultPoint.hit("statemachine.work")
                    await MachineContext.$stateWork.withValue(context) { await work(sender) }
                }
            }
        }
        let wrapper = Task.stoic {
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                cause.record(.stateExited)
                task.cancel()
            }
        }
        return Running(task: wrapper, label: activity.label, shutdownTimeout: activity.shutdownTimeout, watch: AbandonmentWatch.current)
    }

    private func makeSender(visit: UInt64) -> Sender {
        Sender { [weak self] event in
            self?.apply(event, onlyDuring: visit)
        }
    }
}

/// What the current task is doing for a state machine. (A generic type
/// cannot hold a task-local.)
private enum MachineContext {
    /// The machine and visit whose state work this is.
    struct StateWork: Sendable {
        let machine: ObjectIdentifier
        let visit: UInt64
    }

    /// Whether this task (or thread) is inside a transition function or a
    /// `whileIn` predicate, which run while a machine holds its lock.
    @TaskLocal static var transitioning = false

    /// Set while state work runs, and inherited by the tasks it starts, so
    /// that the machine's own `send` drops their events once the visit ends,
    /// as their `Sender` does: work that captured the machine cannot
    /// deliver a stale event either.
    @TaskLocal static var stateWork: StateWork?
}

extension CancellationCause {
    /// The state machine left the state the work belonged to.
    public static let stateExited = CancellationCause(rawValue: "state_exited")
}
