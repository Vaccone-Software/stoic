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

    /// The run ended — the process exited, crashed or was ended — before
    /// the reply arrived. `afterSending` says whether the request had been
    /// sent; if it had, the service may have acted on it.
    case lost(afterSending: Bool)

    /// The attempt was cancelled, by its caller or its own timeout, before
    /// the reply arrived. The service was told to cancel the request.
    case cancelled(afterSending: Bool)

    /// `ifRunning` was asked and no run was live: nothing was started.
    case notRunning

    /// The service is another build than the app. The app was replaced on
    /// disk while it ran; it should restart.
    case buildMismatch(expected: String, found: String)

    /// No run can be had: the service is not in the bundle, the peer was
    /// shut down, or the last run would not exit.
    case unavailable(String)

    /// The two sides disagree about a method: the service has no handler for
    /// it, or a request or reply did not decode as its type. A bug, or a
    /// build mismatch the handshake missed.
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
        case .cancelled(let sent): "cancelled \(sent ? "after" : "before") the request was sent"
        case .notRunning: "the service is not running"
        case .buildMismatch(let expected, let found): "the service is build \(found), the app is build \(expected)"
        case .unavailable(let why): "the service is unavailable: \(why)"
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
        case .lost, .cancelled:
            .retry
        case .notRunning, .buildMismatch, .unavailable, .protocolViolation:
            .stop
        }
    }

    /// True when the request was certainly not run: never sent, or refused
    /// by a service that did not run it.
    public var neverReachedBackend: Bool {
        switch self {
        case .lost(let sent), .cancelled(let sent):
            !sent
        case .notRunning, .buildMismatch, .unavailable:
            true
        case .failed, .protocolViolation:
            false
        }
    }
}

extension XPCCallError: Equatable where Failure: Equatable {}
#endif
