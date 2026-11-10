public import Observation
public import Stoic
internal import Synchronization

/// Something a person triggers: the write side of a screen (design/31).
///
///     let signUp = Action(Events.signUp, whileRunning: .join, refreshes: [attendees]) { [api] id, attempt in
///         try await api.signUp(id, idempotencyKey: attempt.idempotencyKey)    // one key per intent
///     }
///     Button("Sign up") { signUp.trigger(event.id) }                         // a second tap joins the first
///
/// **A second trigger while one runs is never fired blindly**: it is refused
/// (`.refuse`, the default) or, with an equal input, joins the run in
/// progress (`.join`). Disabling the button is still good manners;
/// correctness no longer depends on it.
///
/// **One intent, one key.** Every attempt of every run within one intent sends
/// the same `attempt.idempotencyKey`, so a retried `.keyed` sign-up is one
/// commitment. An intent starts at a trigger from `.idle` or `.succeeded`; from
/// `.failed` with a different input, or after the backend answered for good
/// (an `.executed` outcome). A trigger after an `.unknown` or `.notExecuted`
/// outcome with an equal input continues the intent, so "Try again" after a lost
/// connection is the same request. After an unknown outcome on a
/// `.notRepeatable` operation, `trigger` is refused (`.outcomeUnknown`) until
/// ``reset()``: the effect may already have happened, and the person checks
/// first. ``reset()`` ends the intent.
///
/// **A failure is always surfaced**: presented once (`failure.presented`,
/// `action.failed`), held in ``phase`` until the next trigger or ``reset()``.
/// One that is replaced, or whose action is released, without ``phase`` ever
/// being read after it is reported as `action.failure_unseen`: an empty `catch`,
/// made visible.
///
/// **The run belongs to the action.** A view that disappears does not cancel a
/// payment the person asked for; a caller of ``run(_:)`` that is cancelled
/// stops waiting, and the run goes on. Releasing the action cancels its run (a
/// brief keyed or non-repeatable attempt in flight finishes, shielded, as
/// `perform` does).
@MainActor
public final class Action<Input: Sendable, Output: Sendable>: Observable {
    /// Where the action is.
    public enum Phase {
        case idle
        case running
        case succeeded(Output)
        case failed(Presented)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// What a second trigger does while one runs.
    public enum WhileRunning: Sendable, Hashable {
        /// It is refused (the default): refusing is always safe.
        case refuse
        /// With an equal input it waits for the run in progress; with another,
        /// it is refused, since two intents cannot share one request.
        case join
    }

    /// What a trigger did.
    public enum Trigger: Sendable, Hashable {
        case started, joined
        case refused(Refusal)

        public enum Refusal: Sendable, Hashable {
            /// A run is in progress.
            case running
            /// A non-repeatable operation's outcome is unknown: check, then `reset()`.
            case outcomeUnknown
        }
    }

    /// Names the action in events.
    public let label: String

    private let safety: RepeatSafety
    private let whileRunning: WhileRunning
    private let urgency: Urgency
    private let refreshes: [WeakRefreshable]
    private let same: @MainActor (Input, Input) -> Bool
    private let body: @concurrent @Sendable (Input, IdempotencyKey, Urgency) async -> Result<Output, RunFailure>

    private let registrar = ObservationRegistrar()
    private let phaseKeyPath: KeyPath<Action, Phase> = \.phase
    /// The phase, without counting as a read.
    private(set) var current: Phase = .idle
    private var running: Input?
    private var intent: (key: IdempotencyKey, input: Input)?
    private var lastFailure: (input: Input, outcome: RunFailure.Outcome, reference: SupportReference)?
    private var blocked = false
    private var failureSeen = true
    private let waiters = Mutex(LoadWaiters())
    private let slot: TaskSlot<Result<Output, RunFailure>, Never>
    /// Where the action was made: its deinit sees no task-local values, and
    /// reports an unseen failure here.
    private let instrumentation: any Instrumentation

    private init(
        operation: Backend.Operation, whileRunning: WhileRunning, urgency: Urgency, refreshes: [any Refreshable], label: String?,
        same: @escaping @MainActor (Input, Input) -> Bool,
        body: @escaping @concurrent @Sendable (Input, IdempotencyKey, Urgency) async -> Result<Output, RunFailure>
    ) {
        self.label = label ?? "\(operation.backend.name).\(operation.name)"
        safety = operation.safety
        self.whileRunning = whileRunning
        self.urgency = urgency
        self.refreshes = refreshes.map(WeakRefreshable.init)
        self.same = same
        self.body = body
        slot = TaskSlot(label: "action.\(self.label)")
        instrumentation = Ambient.current.instrumentation
    }

    /// An action on a declared operation, whose input says what the person
    /// asked for.
    ///
    /// - Parameters:
    ///   - operation: The declared operation each run performs.
    ///   - whileRunning: What a second trigger does while one runs.
    ///   - urgency: Who waits: `.interactive` by default, a person tapped.
    ///   - refreshes: Lives a success makes stale, invalidated together in one
    ///     main-actor turn; held weakly.
    ///   - label: Names it in events; the operation's label by default.
    ///   - perform: One attempt, off the main actor; send
    ///     `attempt.idempotencyKey`, which is the intent's.
    public convenience init<Failure: Error>(
        _ operation: Backend.Operation, whileRunning: WhileRunning = .refuse, urgency: Urgency = .interactive,
        refreshes: [any Refreshable] = [], label: String? = nil,
        perform: @escaping @concurrent @Sendable (Input, Attempt) async throws(Failure) -> Output
    ) where Input: Equatable {
        self.init(
            operation: operation, whileRunning: whileRunning, urgency: urgency, refreshes: refreshes, label: label, same: { $0 == $1 },
            body: Self.body(operation, label: label) { input, attempt throws(Failure) in try await perform(input, attempt) })
    }

    /// An action with no input: every trigger asks for the same thing.
    public convenience init<Failure: Error>(
        _ operation: Backend.Operation, whileRunning: WhileRunning = .refuse, urgency: Urgency = .interactive,
        refreshes: [any Refreshable] = [], label: String? = nil,
        perform: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> Output
    ) where Input == Void {
        self.init(
            operation: operation, whileRunning: whileRunning, urgency: urgency, refreshes: refreshes, label: label, same: { _, _ in true },
            body: Self.body(operation, label: label) { _, attempt throws(Failure) in try await perform(attempt) })
    }

    private static func body<Failure: Error>(
        _ operation: Backend.Operation, label: String?, _ perform: @escaping @Sendable (Input, Attempt) async throws(Failure) -> Output
    ) -> @concurrent @Sendable (Input, IdempotencyKey, Urgency) async -> Result<Output, RunFailure> {
        let name = label ?? "\(operation.backend.name).\(operation.name)"
        return { @concurrent input, key, urgency in
            let outcome = await withUrgency(urgency) { () async -> Result<Output, RunFailure> in
                do throws(OperationError<Failure>) {
                    return .success(try await operation.perform(idempotencyKey: key) { attempt throws(Failure) in
                        try await perform(input, attempt)
                    })
                } catch {
                    return .failure(RunFailure(error: error, outcome: RunFailure.Outcome(error.outcome)))
                }
            }
            // Cancelled only when its action was released: a shielded attempt
            // may still have finished, and nobody is left to show it.
            if Task.isCancelled { Self.reportOrphaned(outcome, label: name) }
            return outcome
        }
    }

    private nonisolated static func reportOrphaned(_ outcome: Result<Output, RunFailure>, label: String) {
        let ended: String = switch outcome {
        case .success: "succeeded"
        case .failure(let failure): failure.outcome.rawValue
        }
        Ambient.record(Event("action.orphaned", level: .notice, label: label, fields: [
            .init("outcome", .string(ended), privacy: .public),
        ]))
    }

    isolated deinit {
        reportIfUnseen(to: instrumentation)
    }

    // MARK: Reading

    /// The phase: observable. Reading it while it holds a failure is what
    /// counts as the failure having been seen.
    public var phase: Phase {
        registrar.access(self, keyPath: phaseKeyPath)
        if case .failed = current { failureSeen = true }
        return current
    }

    // MARK: Triggering

    /// Asks for a run with `input`: started, joined, or refused, as declared.
    @discardableResult
    public func trigger(_ input: Input) -> Trigger {
        if let running {
            if whileRunning == .join, same(input, running) {
                Ambient.record(level: .debug) { Event("action.joined", level: .debug, label: label) }
                return .joined
            }
            refuse("running")
            return .refused(.running)
        }
        if blocked {
            refuse("outcome_unknown")
            return .refused(.outcomeUnknown)
        }
        // The intent: continued after a failure whose outcome left the request
        // repeatable under its key, with the same input; otherwise new.
        let key: IdempotencyKey
        if case .failed = current, let failed = lastFailure, failed.outcome != .executed, same(input, failed.input), let intent {
            key = intent.key
        } else {
            key = IdempotencyKey.random()
        }
        reportIfUnseen()
        intent = (key, input)
        running = input
        lastFailure = nil
        change { current = .running }
        let body = body
        let urgency = urgency
        slot.run(for: self) { () async -> Result<Output, RunFailure> in
            await body(input, key, urgency)
        } deliver: { @MainActor action, result in
            switch result {
            case .success(let outcome): action.finished(input, outcome)
            }
        }
        return .started
    }

    /// ``trigger(_:)``, then waits for that run's end (the one it started or
    /// joined) and returns its phase. A refused trigger returns the phase at
    /// once; a cancelled caller stops waiting, and the run goes on.
    public func run(_ input: Input) async -> Phase {
        switch trigger(input) {
        case .started, .joined: await waitForEnd()
        case .refused: break
        }
        return phase
    }

    /// Back to `.idle`: the intent ends, and a trigger refused after an unknown
    /// outcome is allowed again. While a run is in progress it changes
    /// nothing: the run's outcome still lands.
    public func reset() {
        guard running == nil else { return }
        reportIfUnseen()
        blocked = false
        intent = nil
        lastFailure = nil
        change { current = .idle }
    }

    // MARK: Internals

    private func finished(_ input: Input, _ outcome: Result<Output, RunFailure>) {
        running = nil
        switch outcome {
        case .success(let output):
            change { current = .succeeded(output) }
            // Together, in this turn: a combination over them keeps its old
            // snapshot until all of them have landed.
            for refreshable in refreshes { refreshable.target?.invalidate() }
        case .failure(let failure):
            // A cancelled run presents nothing and leaves `.idle`.
            guard let presented = failure.error.presented() else {
                intent = nil
                change { current = .idle }
                break
            }
            Ambient.record(Event("action.failed", level: .notice, label: label, fields: [
                .init("reference", .string(presented.reference.description), privacy: .public),
                .init("outcome", .string(failure.outcome.rawValue), privacy: .public),
            ]))
            lastFailure = (input, failure.outcome, presented.reference)
            if failure.outcome == .unknown, safety == .notRepeatable { blocked = true }
            failureSeen = false
            change { current = .failed(presented) }
        }
        for waiter in waiters.withLock({ $0.takeAll() }) { waiter.resume() }
    }

    /// Returns when the run in progress ends, or when the caller is cancelled.
    func waitForEnd() async {
        guard running != nil else { return }
        let id = waiters.withLock { $0.next() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !waiters.withLock({ $0.park(id, continuation) }) { continuation.resume() }
            }
        } onCancel: {
            waiters.withLock { $0.cancel(id) }?.resume()
        }
    }

    private func refuse(_ why: String) {
        Ambient.record(level: .debug) {
            Event("action.refused", level: .debug, label: label, fields: [.init("why", .string(why), privacy: .public)])
        }
    }

    /// A failure nobody read is about to be replaced or released.
    private func reportIfUnseen(to instrumentation: (any Instrumentation)? = nil) {
        guard case .failed(let presented) = current, !failureSeen else { return }
        failureSeen = true
        let event = Event("action.failure_unseen", level: .warning, label: label, fields: [
            .init("reference", .string(presented.reference.description), privacy: .public),
        ])
        if let instrumentation {
            if instrumentation.isEnabled(.warning) { instrumentation.record(event) }
        } else {
            Ambient.record(event)
        }
    }

    private func change(_ mutation: () -> Void) {
        registrar.withMutation(of: self, keyPath: phaseKeyPath, mutation)
    }
}

extension Action where Input == Void {
    /// Asks for a run.
    @discardableResult
    public func trigger() -> Trigger {
        trigger(())
    }

    /// ``trigger()``, then waits for that run's end and returns its phase.
    public func run() async -> Phase {
        await run(())
    }
}

extension Action.Phase: Sendable {}

extension Action.Phase: Equatable where Output: Equatable {}

/// Why a run failed, and what is known of the backend's side.
struct RunFailure: Error {
    enum Outcome: String, Sendable {
        case notExecuted, executed, unknown

        init<F>(_ outcome: OperationError<F>.Outcome) {
            switch outcome {
            case .notExecuted: self = .notExecuted
            case .executed: self = .executed
            case .unknown: self = .unknown
            }
        }
    }

    let error: any Error
    let outcome: Outcome
}

/// An action's `refreshes`, held weakly: a screen's lives go with the screen.
@MainActor
struct WeakRefreshable {
    weak var target: (any Refreshable)?

    init(_ target: any Refreshable) {
        self.target = target
    }
}
