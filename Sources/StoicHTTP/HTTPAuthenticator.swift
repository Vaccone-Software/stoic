public import Stoic

/// Adds credentials that depend on the request itself to every attempt: a
/// signature, a proof of possession (design/29). Nothing here is about App
/// Attest; DPoP or a request-signing scheme fits the same three calls.
///
///     let client = HTTPClient(base: api, headers: auth, authenticator: signer)
///
/// The client calls it only for requests that carry its own headers: the base
/// URL's origin, while a redirect chain has not left it (design/19), and not
/// for a call whose ``HTTPOverrides/authenticate`` is `false`.
///
/// - ``prepare(_:)`` runs before the host's retry, breaker, rate limit and
///   bulkhead, before each send of a hop (its first, and a replay): a wait
///   there (an enrolment, a token) holds none of the host's slots. The
///   caller's deadline bounds it.
/// - ``authenticate(_:)`` runs at the start of every attempt, retries
///   included, before the attempt's timeout starts: its headers go on that
///   attempt only, so every retry is signed afresh. It must not send through
///   this client.
/// - ``received(_:to:)`` sees every response to an authenticated attempt,
///   successes included, before retry classification and the
///   reauthentication hook. It may ask for one replay per hop
///   (``HTTPAuthenticatorVerdict/replay``), or end the call
///   (``HTTPAuthenticatorVerdict/refuse(_:)``).
///
/// A throw from `prepare` or `authenticate` fails the call
/// ``HTTPError/authenticationFailed(_:attempts:)``, unless the caller was
/// cancelled, which is `CancellationError` as for any call.
public protocol HTTPAuthenticator: Sendable {
    /// Before the host's policies, before each send of a hop: may wait.
    /// Default: nothing.
    func prepare(_ request: HTTPRequest) async throws(HTTPAuthenticationError)

    /// At the start of every attempt, retries included: the headers to add
    /// to this attempt, which replace any of the same name. `request` is the
    /// request as it will be sent, with the client's headers and its
    /// idempotency key.
    func authenticate(_ request: HTTPRequest) async throws(HTTPAuthenticationError) -> HTTPHeaders

    /// Every response to an authenticated attempt, before anything else sees
    /// it. `request` is the attempt as it was sent, with ``authenticate(_:)``'s
    /// headers. Default: ``HTTPAuthenticatorVerdict/accept``.
    func received(_ response: HTTPResponse, to request: HTTPRequest) async -> HTTPAuthenticatorVerdict
}

extension HTTPAuthenticator {
    public func prepare(_ request: HTTPRequest) async throws(HTTPAuthenticationError) {}

    public func received(_ response: HTTPResponse, to request: HTTPRequest) async -> HTTPAuthenticatorVerdict {
        .accept
    }
}

/// What an authenticator makes of a response.
public enum HTTPAuthenticatorVerdict: Sendable, Hashable {
    /// As if there were no authenticator: a `401` still reaches the
    /// reauthentication hook.
    case accept
    /// Prepare, authenticate and send once more. A replay counts as an
    /// attempt and takes nothing from the retry schedule; it happens at most
    /// once per hop. A second `.replay` in the hop is not honoured: the
    /// response is the answer, and the reauthentication hook does not run for
    /// it.
    case replay
    /// The call fails ``HTTPError/authenticationFailed(_:attempts:)`` with
    /// this, and the reauthentication hook does not run.
    case refuse(HTTPAuthenticationError)
}

/// Why an authenticator could not, or would not, authenticate a request.
///
/// Carries a scheme and a code, never a credential: it is what events,
/// descriptions and logs see.
public struct HTTPAuthenticationError: Error, Sendable, Hashable, Retryable, CustomStringConvertible {
    /// The authentication scheme, such as `AppAttest`.
    public let scheme: String
    /// What happened, in the scheme's words: `unsupported`, `revoked`,
    /// `invalid`, `timed_out`.
    public let code: String
    /// How a retry layer should take it.
    public let retryDecision: RetryDecision

    public init(scheme: String, code: String, retryDecision: RetryDecision) {
        self.scheme = scheme
        self.code = code
        self.retryDecision = retryDecision
    }

    public var description: String { "\(scheme) authentication failed: \(code)" }
}
