#if os(macOS)
public import Stoic

/// Why one attempt of a call to a service failed: the failure a call's
/// `OperationError` carries as `last`.
///
/// Whether the request reached the service is part of every failure that
/// can follow a send, so a declared operation knows whether it may send it
/// again (design/22): a request that was never sent is repeated whatever its
/// repeat safety; one lost after it was sent only when its declaration
/// allows.
public enum XPCCallError<Failure: Error & Sendable>: Error, Sendable, CustomStringConvertible {
    /// The handler threw its declared failure: the service's answer.
    case failed(Failure)

    /// The run ended on its own — the process crashed, exited idle, or its
    /// watchdog ended it — before the reply arrived. `afterSending` says
    /// whether the request had been sent; if it had, the service may have
    /// acted on it.
    case lost(afterSending: Bool)

    /// The app ended the run the request was on — ``XPCPeer/end(reason:)``,
    /// a stuck request, ``XPCPeer/shutdown()`` — before the reply arrived.
    /// Like ``lost(afterSending:)``, except that the breaker does not count
    /// it: the service did not fail.
    case ended(afterSending: Bool)

    /// The attempt was cancelled, by its caller or its own timeout, before
    /// the reply arrived. The service was told to cancel the request.
    case cancelled(afterSending: Bool)

    /// `ifRunning` was asked and no run was live: nothing was started.
    case notRunning

    /// The service is another build than the app. The app was replaced on
    /// disk while it ran; it should restart.
    case buildMismatch(expected: String, found: String)

    /// No run can be had, and the request was not sent.
    case unavailable(XPCUnavailable)

    /// The service refused the request without running it: it has no
    /// handler for the method, or the request did not decode as the
    /// method's type. A bug, or a build mismatch the handshake missed.
    case refused(String)

    /// The request was sent and may have run, but its reply was not one:
    /// it did not decode, or did not say what it was.
    case protocolViolation(String)

    /// The service's failure, if the call failed with one.
    public var failure: Failure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    public var description: String {
        switch self {
        case .failed(let failure): "failed: \(failure)"
        case .lost(let sent): "the service's run was lost \(sent ? "after" : "before") the request was sent"
        case .ended(let sent): "the app ended the service's run \(sent ? "after" : "before") the request was sent"
        case .cancelled(let sent): "cancelled \(sent ? "after" : "before") the request was sent"
        case .notRunning: "the service is not running"
        case .buildMismatch(let expected, let found): "the service is build \(found), the app is build \(expected)"
        case .unavailable(let why): "the service is unavailable: \(why)"
        case .refused(let why): "refused: \(why)"
        case .protocolViolation(let why): "protocol violation: \(why)"
        }
    }
}

extension XPCCallError: Retryable {
    /// A lost run is transient; the service's own failure decides for
    /// itself if it is `Retryable` and is otherwise permanent; everything
    /// else is permanent.
    public var retryDecision: RetryDecision {
        switch self {
        case .failed(let failure):
            (failure as? any Retryable)?.retryDecision ?? .stop
        case .lost, .ended, .cancelled:
            .retry
        case .notRunning, .buildMismatch, .unavailable, .refused, .protocolViolation:
            .stop
        }
    }

    /// True when the request was certainly not run: never sent, or refused
    /// by a service that did not run it.
    public var neverReachedBackend: Bool {
        switch self {
        case .lost(let sent), .ended(let sent), .cancelled(let sent):
            !sent
        case .notRunning, .buildMismatch, .unavailable, .refused:
            true
        case .failed, .protocolViolation:
            false
        }
    }
}

extension XPCCallError: Equatable where Failure: Equatable {}

extension XPCCallError: CallerDecidedFailure {
    /// An end the app decided is not the service failing.
    package var isCallerDecided: Bool {
        if case .ended = self { return true }
        return false
    }
}

/// Why no run of a service can be had.
public enum XPCUnavailable: Sendable, Hashable, CustomStringConvertible {
    /// No session could be made: the service is not in the app's bundle.
    case noSession(String)
    /// A process started but did not shake hands: no answer in time, or an
    /// answer that was not a handshake.
    case noHandshake(String)
    /// The last run would not exit and could not be killed: calls are
    /// refused until it goes.
    case wedged
    /// The peer was shut down.
    case shutDown

    public var description: String {
        switch self {
        case .noSession(let why): "no session: \(why)"
        case .noHandshake(let why): "no handshake: \(why)"
        case .wedged: "the last run would not exit"
        case .shutDown: "the peer was shut down"
        }
    }
}
#endif
