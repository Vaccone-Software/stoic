internal import Synchronization

/// What ``Debouncer`` and ``Throttler`` share: one decision per call, and one
/// call at a time waiting for its turn.
///
/// Both policies keep an *edge* in time and at most one *pending* call. A call
/// arriving before the edge is inside the burst (debounce) or window
/// (throttle); one arriving after it starts a new one. What differs is only
/// where the edge goes: a debouncer moves it to `now + period` on every call,
/// so the burst lasts as long as calls keep coming; a throttler fixes it when
/// the window opens (and again when a trailing call runs), so the window is
/// the same length however many calls arrive in it.
///
/// A pending call waits in its caller's own task, on a timer that is a child
/// of that wait. Nothing is started that the call does not own, so nothing can
/// outlive the caller: cancelling the call withdraws it, and a scope that
/// forks the call (``Debouncer/submit(in:label:_:)``) cancels the timer with
/// the scope.
///
/// Every call ends in exactly one fate. The ticket's fate is decided by
/// whoever removes the ticket from `pending` under the lock (the timer, a
/// newer call, or the caller's cancellation), so it is resolved once.
final class CallShaper: Sendable {
    enum Mode: Sendable { case debounce, throttle }

    enum Fate: Sendable {
        case run, superseded, suppressed, cancelled
    }

    private final class Ticket: Sendable {
        let id: UInt64
        let fate = OnceCell<Fate>()
        init(id: UInt64) { self.id = id }
    }

    private struct State {
        var edge: AnyClock.Instant?
        var pending: Ticket?
        var nextID: UInt64 = 0
    }

    private enum Step {
        case run
        case suppress
        case park(Ticket, until: AnyClock.Instant, replacing: Ticket?)
    }

    let mode: Mode
    let period: Duration
    let leading: Bool
    let trailing: Bool
    let label: String
    let clock: AnyClock
    private let dropped: EventName
    private let state = Mutex(State())

    init(mode: Mode, period: Duration, leading: Bool, trailing: Bool, label: String, clock: AnyClock?, dropped: EventName) {
        precondition(period > .zero, "the \(mode == .debounce ? "quiet period" : "interval") must be positive")
        precondition(leading || trailing, "a call that runs neither first nor last never runs")
        self.mode = mode
        self.period = period
        self.leading = leading
        self.trailing = trailing
        self.label = label
        self.clock = clock ?? Ambient.current.clock
        self.dropped = dropped
    }

    /// Runs `operation` if this call's fate is to run, else throws why not.
    nonisolated(nonsending) func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        if let refusal = Rejection.refusedBeforeStart(label: label) { throw .rejected(refusal) }
        let reason: Rejection.Reason
        switch await enter() {
        case .run:
            do throws(Failure) {
                return try await operation()
            } catch {
                throw .failed(error)
            }
        case .cancelled:
            throw .rejected(Rejection(.cancelled, label: label).attributingDeadline())
        case .superseded:
            reason = .superseded
        case .suppressed:
            reason = .suppressed
        }
        Ambient.record(level: .debug) {
            Event(dropped, level: .debug, label: label, fields: [.init("reason", .string(reason.rawValue), privacy: .public)])
        }
        throw .rejected(Rejection(reason, label: label))
    }

    /// ``execute(_:)`` from a fork of `scope`; only an error of the operation
    /// itself ends the fork in failure.
    func submit(in scope: borrowing TaskScope, label: String, _ operation: @escaping @Sendable () async throws -> Void) {
        scope.fork(label: label) {
            do throws(PolicyError<any Error>) {
                try await self.execute { try await operation() }
            } catch {
                if case .failed(let failure) = error { throw failure }
            }
        }
    }

    private nonisolated(nonsending) func enter() async -> Fate {
        let now = clock.now
        let step = state.withLock { state -> Step in
            let open = state.pending != nil || (state.edge.map { now < $0 } ?? false)
            if !open, leading {
                state.edge = now.advanced(by: period)
                return .run
            }
            if open, !trailing {
                if mode == .debounce { state.edge = now.advanced(by: period) }
                return .suppress
            }
            let due: AnyClock.Instant
            if open, mode == .throttle, let edge = state.edge {
                due = edge
            } else {
                due = now.advanced(by: period)
                state.edge = due
            }
            state.nextID += 1
            let ticket = Ticket(id: state.nextID)
            defer { state.pending = ticket }
            return .park(ticket, until: due, replacing: state.pending)
        }
        switch step {
        case .run:
            return .run
        case .suppress:
            return .suppressed
        case .park(let ticket, let due, let replaced):
            replaced?.fate.resolve(.superseded)
            return await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do {
                            try await self.clock.sleep(until: due, tolerance: nil)
                            self.settle(ticket, as: .run)
                        } catch {}
                    }
                    let fate = await ticket.fate.value
                    group.cancelAll()
                    return fate
                }
            } onCancel: {
                self.settle(ticket, as: .cancelled)
            }
        }
    }

    /// Gives `ticket` its fate if it is still the pending call.
    private func settle(_ ticket: Ticket, as fate: Fate) {
        let now = clock.now
        let owned = state.withLock { state -> Bool in
            guard state.pending === ticket else { return false }
            state.pending = nil
            // A trailing run opens the next window.
            if fate == .run, mode == .throttle { state.edge = now.advanced(by: period) }
            return true
        }
        if owned { ticket.fate.resolve(fate) }
    }
}

extension Rejection.Reason {
    /// A newer call replaced this one before it could run.
    public static let superseded = Rejection.Reason(rawValue: "superseded")
    /// The call fell inside a quiet period or window that lets no further call run.
    public static let suppressed = Rejection.Reason(rawValue: "suppressed")
}
