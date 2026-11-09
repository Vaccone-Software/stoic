#if os(macOS)
public import Stoic
internal import Synchronization

/// One run of the service, as the peer sees it: from the session it opened
/// to the first sign that the process is gone.
final class RunState: Sendable {
    /// What a handshake came to, for the calls waiting on it.
    enum Readiness: Sendable {
        case live(XPCRun)
        /// The process was lost before it answered, or never answered.
        case lost
        /// The process answered that it is exiting: wait for it to go, and
        /// start another.
        case retry
        case unavailable(XPCUnavailable)
        case buildMismatch(expected: String, found: String)
    }

    /// A request in flight on this run.
    private struct Pending {
        /// Settles the request's attempt as lost.
        var fail: @Sendable () -> Void
        /// Its reply has arrived (late, if its caller has left).
        var answered = false
        /// Its caller has left; the entry stays until the reply arrives or
        /// the run ends, so a stuck request can be told from a late one.
        var abandoned = false
    }

    private struct Mutable {
        var connection: (any XPCConnection)?
        var info: XPCRun?
        var pending: [UInt64: Pending] = [:]
        var ended = false
        /// Why the run is ending, and since when; `nil` while it is not.
        var endReason: String?
        var endAskedAt: AnyClock.Instant?
        /// Whether the app decided the end: its calls fail `.ended`, which
        /// the breaker does not count.
        var appDecided = false
        var ending: Gate<XPCEndResult>?
    }

    let number: Int
    let startedAt: AnyClock.Instant

    /// Opened once, when the handshake is decided.
    let ready = Gate<Readiness>()

    /// Opened once, when the process is gone (`true`) or would not go
    /// (`false`, wedged): what a call made while the run is ending waits
    /// for.
    let settled = Gate<Bool>()

    private let mutable = Mutex(Mutable())

    init(number: Int, startedAt: AnyClock.Instant) {
        self.number = number
        self.startedAt = startedAt
    }

    var connection: (any XPCConnection)? {
        mutable.withLock { $0.connection }
    }

    var info: XPCRun? {
        mutable.withLock { $0.info }
    }

    var hasEnded: Bool {
        mutable.withLock { $0.ended }
    }

    var endReason: String? {
        mutable.withLock { $0.endReason }
    }

    var endAskedAt: AnyClock.Instant? {
        mutable.withLock { $0.endAskedAt }
    }

    /// Whether the app decided the run's end.
    var endedByApp: Bool {
        mutable.withLock { $0.appDecided }
    }

    /// Keeps the session. False if the run already ended: the caller cancels it.
    func attach(_ connection: any XPCConnection) -> Bool {
        mutable.withLock { state in
            guard !state.ended else { return false }
            state.connection = connection
            return true
        }
    }

    func setInfo(_ info: XPCRun) {
        mutable.withLock { $0.info = info }
    }

    /// Marks the run as asked to end, once. Returns the gate the end's
    /// outcome opens, and whether this call is the one that asked.
    func askToEnd(reason: String, byApp: Bool, at instant: AnyClock.Instant) -> (outcome: Gate<XPCEndResult>, first: Bool) {
        mutable.withLock { state in
            if let ending = state.ending { return (ending, false) }
            let ending = Gate<XPCEndResult>()
            state.ending = ending
            if state.endReason == nil {
                state.endReason = reason
                state.endAskedAt = instant
                state.appDecided = byApp
            }
            return (ending, true)
        }
    }

    /// Records why the run is ending when the peer is not the one running
    /// its end: the service said it is exiting (`byApp` false), or the peer
    /// shut down or found another build (`byApp` true). The first reason
    /// stays.
    func noteEnd(reason: String, byApp: Bool, at instant: AnyClock.Instant) {
        mutable.withLock { state in
            if state.endReason == nil {
                state.endReason = reason
                state.endAskedAt = instant
                state.appDecided = byApp
            }
        }
    }

    /// Ends the run, once: the first sign that the process is gone wins.
    /// Returns the requests still waiting, to be failed, and the session, to
    /// be cancelled — the run lets go of it, so neither keeps the other —
    /// or `nil` if the run had ended already.
    func end() -> (failures: [@Sendable () -> Void], connection: (any XPCConnection)?)? {
        mutable.withLock { state in
            guard !state.ended else { return nil }
            state.ended = true
            let failures = state.pending.values.filter { !$0.answered && !$0.abandoned }.map(\.fail)
            state.pending = [:]
            defer { state.connection = nil }
            return (failures, state.connection)
        }
    }

    // MARK: Requests

    /// Files request `id`. False if the run has ended or is ending: nothing
    /// is sent, so nothing can reach a process that is leaving.
    func register(_ id: UInt64, fail: @escaping @Sendable () -> Void) -> Bool {
        mutable.withLock { state in
            guard !state.ended, state.endReason == nil else { return false }
            state.pending[id] = Pending(fail: fail)
            return true
        }
    }

    /// The reply to `id` arrived.
    func answered(_ id: UInt64) {
        mutable.withLock { state in
            guard var pending = state.pending[id] else { return }
            if pending.abandoned {
                state.pending[id] = nil
            } else {
                pending.answered = true
                state.pending[id] = pending
            }
        }
    }

    /// The attempt for `id` is over with its reply in hand, or never sent.
    func finished(_ id: UInt64) {
        mutable.withLock { _ = $0.pending.removeValue(forKey: id) }
    }

    /// The caller of `id` has left. Returns whether its reply is still
    /// awaited: false if it already arrived.
    func abandon(_ id: UInt64) -> Bool {
        mutable.withLock { state in
            guard var pending = state.pending[id] else { return false }
            if pending.answered {
                state.pending[id] = nil
                return false
            }
            pending.abandoned = true
            state.pending[id] = pending
            return true
        }
    }

    /// Whether request `id`, whose caller left, is still unanswered on a
    /// live run.
    func isStillUnanswered(_ id: UInt64) -> Bool {
        mutable.withLock { state in
            guard !state.ended, let pending = state.pending[id] else { return false }
            return !pending.answered
        }
    }
}
#endif
