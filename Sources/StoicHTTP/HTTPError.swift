public import Foundation
public import Stoic
public import StoicSchema
internal import StoicFoundation

/// Why a request failed, as one typed value.
///
/// Each case says how many ``attempts`` were made, which is how a caller (or
/// a test) tells "failed at once" from "failed after retrying": an attempt is
/// one request that reached the transport. A request the breaker, the
/// bulkhead or the deadline turned away before it was ever sent has made
/// none.
///
/// A caller that is cancelled gets `CancellationError`, not an `HTTPError`:
/// cancellation is not a failure of the request, and is never wrapped.
public enum HTTPError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The server answered with a status outside 2xx. `excerpt` is the start
    /// of the body (at most ``HTTPPolicy/errorExcerptBytes`` bytes), where
    /// APIs put their explanation; `retryAfter` is the server's `Retry-After`
    /// as sent, before the policy capped it.
    case status(Int, excerpt: String, retryAfter: Duration?, attempts: Int)

    /// The request did not complete: the network failed in the way `code`
    /// names.
    case transport(URLError.Code, attempts: Int)

    /// The last attempt (number `attempt`) did not finish within
    /// ``HTTPPolicy/attemptTimeout``.
    case timedOut(attempt: Int)

    /// The response body was longer than ``HTTPPolicy/maxResponseBytes``; the
    /// transfer was cancelled when it passed `limit`. Never retried.
    case responseTooLarge(limit: Int, attempts: Int)

    /// The body did not match the schema: every issue, with its path. Never
    /// retried, because asking again will not change the server's mind.
    case decoding(ValidationFailure, attempts: Int)

    /// A policy turned the request away: the breaker is open
    /// (`circuit_open`), the bulkhead is full (`bulkhead_full`), the host's
    /// rate limit would make the request wait too long or the queue is full
    /// (`rate_limited`), the retry budget is spent (`budget_exhausted`), or
    /// the deadline passed, or would pass before the next attempt could
    /// finish (`deadline_exceeded`). A rejection that carries a
    /// ``Rejection/retryAfter`` says when to try again.
    case rejected(Rejection, attempts: Int)

    /// The server answered `401` and the client's reauthentication hook
    /// (``HTTPClient/init(base:policy:transport:headers:label:reauthenticate:)``)
    /// failed, so the request was not replayed. `status` is the 401; the
    /// hook's own error is not kept (it may hold a credential), only its type
    /// is recorded, in the `http.reauthenticate_failed` event. A `401` that
    /// the *replay* got is an ordinary ``status(_:excerpt:retryAfter:attempts:)``:
    /// the hook runs at most once per request.
    case reauthenticationFailed(status: Int, attempts: Int)

    /// The server redirected the request and the client would not follow
    /// (``RedirectRefusal`` says why). `status` and `location` are the
    /// redirect's, `location` as the server sent it: a caller that wants to
    /// follow it some other way (an OAuth callback on an app's own scheme)
    /// reads it here. It may hold a token, so ``description`` never shows it.
    /// Never retried: the server will redirect the same way again.
    case redirectRefused(RedirectRefusal, status: Int, location: String, attempts: Int)

    /// Why the client did not follow a redirect.
    public enum RedirectRefusal: String, Sendable, Hashable {
        /// The request was `https` and the `Location` is `http`: following it
        /// would send the request, and anything in it, in the clear.
        case downgrade
        /// The request had already followed ``HTTPPolicy/maxRedirects``.
        case limit
        /// The `Location` is not an `http` or `https` URL.
        case invalidLocation = "invalid_location"
    }

    /// How many requests reached the transport before this failure.
    public var attempts: Int {
        switch self {
        case .status(_, _, _, let attempts), .transport(_, let attempts), .responseTooLarge(_, let attempts),
             .decoding(_, let attempts), .rejected(_, let attempts), .reauthenticationFailed(_, let attempts),
             .redirectRefused(_, _, _, let attempts):
            attempts
        case .timedOut(let attempt):
            attempt
        }
    }

    /// Whether the client retried before giving up.
    public var wasRetried: Bool { attempts > 1 }

    /// The status code, for ``status(_:excerpt:retryAfter:attempts:)``.
    public var statusCode: Int? {
        if case .status(let code, _, _, _) = self { code } else { nil }
    }

    /// The rejection, for ``rejected(_:attempts:)``.
    public var rejection: Rejection? {
        if case .rejected(let rejection, _) = self { rejection } else { nil }
    }

    /// A summary with no body, URL or issue text: safe for a log.
    public var description: String {
        let tries = attempts == 1 ? "1 attempt" : "\(attempts) attempts"
        switch self {
        case .status(let code, _, _, _): return "HTTP \(code) after \(tries)"
        case .transport(let code, _): return "transport error \(code.rawValue) after \(tries)"
        case .timedOut: return "timed out on attempt \(attempts)"
        case .responseTooLarge(let limit, _): return "response larger than \(limit) bytes after \(tries)"
        case .decoding(let failure, _): return "response did not match its schema (\(failure.errors.count) errors) after \(tries)"
        case .rejected(let rejection, _): return "rejected: \(rejection) after \(tries)"
        case .reauthenticationFailed(let status, _): return "HTTP \(status), and reauthenticating failed, after \(tries)"
        case .redirectRefused(let refusal, let status, _, _): return "HTTP \(status) redirect not followed (\(refusal.rawValue)) after \(tries)"
        }
    }
}

/// An ``HTTPError`` classifies itself the way the client's default policy
/// does, so an outer layer that must decide (an outbox delivering over HTTP,
/// say) reads the same answer as the client.
///
/// This says whether the *failure* is transient. It cannot know whether the
/// request is safe to repeat: the client already refuses to retry an unkeyed
/// `POST`, and anything retrying around it must carry its own
/// ``IdempotencyKey`` (AGENTS.md, rule 2).
extension HTTPError: Retryable {
    public var retryDecision: RetryDecision {
        switch self {
        case .status(let code, _, let retryAfter, _):
            guard HTTPPolicy.defaultRetryStatuses.contains(code) else { return .stop }
            return retryAfter.map(RetryDecision.retryAfter) ?? .retry
        case .transport(let code, _):
            return URLError(code).retryDecision
        case .timedOut:
            return .retry
        case .responseTooLarge, .decoding, .reauthenticationFailed, .redirectRefused:
            return .stop
        case .rejected(let rejection, _):
            switch rejection.reason {
            case .circuitOpen, .bulkheadFull, .rateLimited:
                return rejection.retryAfter.map(RetryDecision.retryAfter) ?? .retry
            default:
                return .stop
            }
        }
    }
}

/// One failed attempt, before the client has counted attempts: what the
/// pipeline's stages see. The retry classifier and the breaker read this, and
/// only this, which is what keeps "what counts against a host" and "what is
/// retried" in one place.
enum AttemptError: Error, Sendable, CustomStringConvertible {
    /// `verdict` is what the response predicate (``HTTPPolicy/retryOnResponse``)
    /// said about this response, if it said anything.
    case status(code: Int, excerpt: String, retryAfter: Duration?, verdict: RetryDecision?)
    case transport(URLError.Code)
    case timedOut
    case tooLarge(limit: Int)
    /// Cancelled by the caller, by the caller's deadline, or by the attempt's
    /// own timeout: the client tells these apart once the attempt is over.
    case cancelled

    /// Whether this failure says something about the host's health, which is
    /// what a breaker is for: 5xx (never 4xx: the server answered and the
    /// request was wrong), timeouts, and the transport failures that are the
    /// host's or the path's fault. The device being offline, or the user
    /// forbidding cellular data, is not the host's fault: counting it would
    /// open the breaker on a healthy server and keep it open after the
    /// device is back.
    var countsAgainstHost: Bool {
        switch self {
        case .status(let code, _, _, _):
            return code >= 500
        case .timedOut:
            return true
        case .transport(let code):
            switch code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .cancelled:
                return false
            default:
                return URLError(code).retryDecision != .stop
            }
        case .tooLarge, .cancelled:
            return false
        }
    }

    /// What to do next. Nothing is repeated unless the request is safe to
    /// repeat; a status is retried only if the policy lists it, after
    /// `Retry-After` when the server sent one (capped by the policy).
    func decision(policy: HTTPPolicy, safeToRepeat: Bool) -> RetryDecision {
        guard safeToRepeat else { return .stop }
        switch self {
        case .status(let code, _, let retryAfter, let verdict):
            switch verdict {
            case .stop?:
                return .stop
            case .retryAfter(let wait)?:
                return .retryAfter(min(wait, policy.maxRetryAfter))
            case .retry?:
                break
            case nil:
                guard policy.retryStatuses.contains(code) else { return .stop }
            }
            if let retryAfter { return .retryAfter(min(retryAfter, policy.maxRetryAfter)) }
            return .retry
        case .transport(let code):
            return URLError(code).retryDecision
        case .timedOut:
            return .retry
        case .tooLarge, .cancelled:
            return .stop
        }
    }

    /// The failure without its body excerpt: this is what the retry and
    /// breaker events print, and a response body is never recorded.
    var description: String { reason }

    /// A short, public name for the failure, for events.
    var reason: String {
        switch self {
        case .status(let code, _, _, _): "status_\(code)"
        case .transport(let code): "transport_\(code.rawValue)"
        case .timedOut: "timed_out"
        case .tooLarge: "too_large"
        case .cancelled: "cancelled"
        }
    }

    /// The attempt error for what a transport threw.
    init(classifying error: any Error) {
        switch error {
        case let transport as HTTPTransportError:
            switch transport {
            case .responseTooLarge(let limit): self = .tooLarge(limit: limit)
            }
        case is CancellationError:
            self = Task.isCancelled ? .cancelled : .transport(.cancelled)
        case let url as URLError:
            switch url.code {
            case .cancelled: self = Task.isCancelled ? .cancelled : .transport(.cancelled)
            case .timedOut: self = .timedOut
            default: self = .transport(url.code)
            }
        default:
            self = .transport(.unknown)
        }
    }
}
