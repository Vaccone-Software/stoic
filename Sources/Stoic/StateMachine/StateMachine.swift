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
/// **Work belongs to a state.** ``whileIn(_:label:_:)`` registers work that
/// starts each time the machine enters a matching state and is cancelled
/// (``CancellationCause/stateExited``) the moment it leaves. Events that work
/// sends back are delivered only while the machine is still in the *same
/// visit* to that state; a late event from an earlier visit is dropped and
/// reported (`statemachine.stale_event`). This is the structured replacement
/// for phase booleans and the generation counters that guard them.
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
        let matches: @Sendable (State) -> Bool
        let work: @Sendable (Sender) async -> Void
    }

    private struct Core {
        var state: State
        var visit: UInt64 = 0
        var history: [Record] = []
        var stateWork: [Task<Void, Never>] = []
        var activities: [Activity] = []
        var observers: [UInt64: AsyncStream<State>.Continuation] = [:]
        var nextObserver: UInt64 = 0
    }

    private let transition: TransitionFunction
    private let clock: AnyClock
    private let core: Mutex<Core>
    private let registrar = ObservationRegistrar()

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
        core.withLock { core in
            for task in core.stateWork { task.cancel() }
            for observer in core.observers.values { observer.finish() }
        }
    }

    /// The current state.
    ///
    /// Observable: a SwiftUI view (or anything using Observation) that reads
    /// it is updated after every transition.
    public var state: State {
        registrar.access(self, keyPath: \.state)
        return core.withLock { $0.state }
    }

    /// The most recent transitions, oldest first, for diagnostics.
    public var history: [Record] {
        registrar.access(self, keyPath: \.history)
        return core.withLock { $0.history }
    }

    /// Handles `event`: computes the transition and applies it.
    public func send(_ event: Event) {
        apply(event, onlyDuring: nil)
    }

    /// Runs `work` whenever the machine is in a state matching `predicate`,
    /// and cancels it when the machine leaves that state. If the machine is
    /// already in a matching state, the work starts now.
    public func whileIn(
        where predicate: @escaping @Sendable (State) -> Bool,
        label: String,
        _ work: @escaping @Sendable (Sender) async -> Void
    ) {
        let activity = Activity(label: label, matches: predicate, work: work)
        core.withLock { core in
            core.activities.append(activity)
            if predicate(core.state) {
                core.stateWork.append(start(activity, visit: core.visit))
            }
        }
    }

    /// Runs `work` whenever the machine is in `state`; cancels it when the
    /// machine leaves.
    public func whileIn(_ state: State, label: String, _ work: @escaping @Sendable (Sender) async -> Void) {
        whileIn(where: { $0 == state }, label: label, work)
    }

    /// The machine's states as they change, starting with the current one.
    /// Buffers only the newest: an observer sees where the machine is, not
    /// every step it took to get there.
    public func states() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = core.withLock { core -> UInt64 in
            continuation.yield(core.state)
            defer { core.nextObserver += 1 }
            core.observers[core.nextObserver] = continuation
            return core.nextObserver
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

    private func apply(_ event: Event, onlyDuring visit: UInt64?) {
        let outcome = core.withLock { core -> Outcome in
            if let visit, core.visit != visit { return .stale }
            switch transition(core.state, event) {
            case .stay, .ignore:
                return .none
            case .invalid(let reason):
                return .invalid(core.state, reason)
            case .to(let next, let timeout):
                return .moved(enter(next, timeout: timeout, cause: event, core: &core))
            }
        }
        // Observers and events are notified outside the lock: neither an
        // observation callback nor an instrumentation sink may be able to
        // deadlock the machine.
        if case .moved = outcome {
            registrar.withMutation(of: self, keyPath: \.state) {}
            registrar.withMutation(of: self, keyPath: \.history) {}
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

    private func enter(_ next: State, timeout: StateTimeout<Event>?, cause event: Event, core: inout Core) -> Record {
        // Leave: everything the old visit started stops now.
        for task in core.stateWork { task.cancel() }
        core.stateWork.removeAll()
        let record = Record(from: core.state, event: event, to: next, at: clock.now)
        core.visit += 1
        core.state = next
        core.history.append(record)
        if core.history.count > historyLimit { core.history.removeFirst(core.history.count - historyLimit) }
        for observer in core.observers.values { observer.yield(next) }

        // Enter: start the new visit's work and its timer.
        let visit = core.visit
        for activity in core.activities where activity.matches(next) {
            core.stateWork.append(start(activity, visit: visit))
        }
        if let timeout {
            let clock = clock
            // The timer's instant is fixed at entry, not when its task first
            // runs: advancing a test clock right after a transition must fire it.
            let fireAt = clock.now.advanced(by: timeout.after)
            let sender = makeSender(visit: visit)
            core.stateWork.append(TaskLedger.task(.stateTimeout, label: label) {
                do {
                    try await clock.sleep(until: fireAt, tolerance: nil)
                } catch {
                    return
                }
                sender.send(timeout.event)
            })
        }
        return record
    }

    private func start(_ activity: Activity, visit: UInt64) -> Task<Void, Never> {
        let cause = CancellationCauseBox(parent: nil)
        let sender = makeSender(visit: visit)
        let work = activity.work
        let task = TaskLedger.task(.stateWork, label: "\(label).\(activity.label)") {
            // State work belongs to the state, not to whoever sent the event
            // that entered it: it does not inherit the sender's deadline.
            await Deadline.$stored.withValue(nil) {
                await CancellationCauseBox.$current.withValue(cause) {
                    // Late-starting work meets events from a later visit.
                    await FaultPoint.hit("statemachine.work")
                    await work(sender)
                }
            }
        }
        return Task.stoic {
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                cause.record(.stateExited)
                task.cancel()
            }
        }
    }

    private func makeSender(visit: UInt64) -> Sender {
        Sender { [weak self] event in
            self?.apply(event, onlyDuring: visit)
        }
    }
}

extension CancellationCause {
    /// The state machine left the state the work belonged to.
    public static let stateExited = CancellationCause(rawValue: "state_exited")
}
