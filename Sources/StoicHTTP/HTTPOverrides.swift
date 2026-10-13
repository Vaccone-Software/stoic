public import Stoic

/// What one call changes about the client's ``HTTPPolicy``, for that call only.
///
/// A policy is the right default for an API, and the wrong one for the odd
/// request: the report that takes a minute, the health check that must not
/// retry, the status poll that must reach a host whose breaker is open. Name
/// the difference rather than build a second client (which would have its own
/// breaker, bulkhead and retry budget, and share none of what the first has
/// learned about the host):
///
///     try await api.send(.get("/reports/9"), overrides: HTTPOverrides(attemptTimeout: .seconds(90)))
///     try await api.send(.get("/health"), overrides: HTTPOverrides(schedule: Schedule.immediate.attempts(1), bypassBreaker: true))
///
/// Everything not named is the policy's. Retry budget, bulkhead, rate limit,
/// byte limits and statuses stay the client's: they exist to protect the
/// host, which a single call has no standing to loosen.
public struct HTTPOverrides: Sendable {
    /// How long one attempt may take, instead of ``HTTPPolicy/attemptTimeout``.
    public var attemptTimeout: Duration?

    /// The attempts and the waits between them, instead of
    /// ``HTTPPolicy/schedule``. `Schedule.immediate.attempts(1)` turns retrying off for this call.
    public var schedule: BoundedSchedule?

    /// Whether identical `GET`s in flight at once share this one, instead of
    /// ``HTTPPolicy/coalesceGETs``.
    ///
    /// A call only shares a request with calls that ask for the same
    /// ``attemptTimeout``, ``schedule``, ``bypassBreaker`` and
    /// ``reauthenticate``; and a call with a ``retryOnResponse`` closure is
    /// never shared (closures cannot be compared).
    public var coalesce: Bool?

    /// Whether this call skips the host's circuit breaker: it is sent even if
    /// the breaker is open, and what it sees is not counted towards opening it.
    /// For a health check or a status poll that exists to find out whether the
    /// host is back. Default `false`.
    public var bypassBreaker: Bool

    /// Whether a `401` may trigger the client's reauthentication hook. Turn
    /// it off for the request the hook itself sends, which must not trigger
    /// the hook. Default `true`.
    public var reauthenticate: Bool

    /// Decides whether to ask again after a response, instead of
    /// ``HTTPPolicy/retryOnResponse`` (which explains the contract).
    public var retryOnResponse: (@Sendable (HTTPResponse) -> RetryDecision?)?

    public init(
        attemptTimeout: Duration? = nil,
        schedule: BoundedSchedule? = nil,
        coalesce: Bool? = nil,
        bypassBreaker: Bool = false,
        reauthenticate: Bool = true,
        retryOnResponse: (@Sendable (HTTPResponse) -> RetryDecision?)? = nil
    ) {
        precondition(attemptTimeout.map { $0 > .zero } ?? true, "an attempt needs a positive timeout")
        self.attemptTimeout = attemptTimeout
        self.schedule = schedule
        self.coalesce = coalesce
        self.bypassBreaker = bypassBreaker
        self.reauthenticate = reauthenticate
        self.retryOnResponse = retryOnResponse
    }

    /// No overrides: the client's policy as it is.
    public static var none: HTTPOverrides { HTTPOverrides() }
}
