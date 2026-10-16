public import Foundation
public import Stoic
public import StoicSchema
internal import StoicJSON

/// Every number the client's resilience is made of.
///
/// For one host, in a fixed order: the caller's deadline, then retry, then
/// the circuit breaker, then the bulkhead, then the attempt timeout, then the
/// transport. The deadline is not a field: it is the caller's, taken from
/// ``Deadline/current``, and every stage honours it.
///
/// Retry is outside the breaker so that every attempt is judged and a
/// breaker that opens mid-retry stops the retries; the breaker is outside the
/// bulkhead so that a flood of calls to a dead host is refused before it
/// takes a slot; the bulkhead is outside the attempt timeout so that waiting
/// for a slot does not use up an attempt's time.
public struct HTTPPolicy: Sendable {
    /// How long one attempt may take, from the moment it holds a bulkhead
    /// slot to the last byte of the body. Default 10 s.
    public var attemptTimeout: Duration

    /// The attempts and the waits between them. Default: 3 attempts with
    /// fully jittered exponential backoff from 200 ms, capped at 10 s. One
    /// attempt (`.attempts(1)`) turns retrying off.
    public var schedule: BoundedSchedule

    /// The cap on how much retrying may add to the load on the host: see
    /// ``RetryBudget``. Shared by every host of the client that holds this
    /// policy; a copy of the policy shares it too. Each `HTTPPolicy()` makes
    /// its own.
    public var retryBudget: RetryBudget

    /// The statuses worth another attempt. Default: 408, 429, 500, 502, 503
    /// and 504. Any other status is final (the other 4xx are the caller's
    /// fault; the other 5xx will not change).
    public var retryStatuses: Set<Int>

    /// The longest a `Retry-After` is honoured. A server asking for more is
    /// waited for this long, not longer (and never past the caller's
    /// deadline). Default 60 s.
    public var maxRetryAfter: Duration

    /// Decides, for each response the server sent, whether to ask again: the
    /// way to retry on what came back rather than on what was thrown.
    /// `nil` (the default) leaves it to ``retryStatuses``.
    ///
    /// The closure sees every response that arrived whole, whatever its
    /// status, and answers with a ``RetryDecision``, or `nil` to defer to
    /// ``retryStatuses``:
    ///
    /// - `.retry` asks again after the schedule's delay, or after the
    ///   response's `Retry-After` when it has one. A `202` that says
    ///   `Retry-After: 2` is polled; a `200` whose body says `"pending"` is
    ///   asked again.
    /// - `.retryAfter(wait)` asks again after `wait`.
    /// - `.stop` makes the response final, even a status in
    ///   ``retryStatuses``: a `503` that says `Retry-After: 3600` is not
    ///   worth waiting for.
    ///
    /// Every wait is capped at ``maxRetryAfter`` and bound by the caller's
    /// deadline, the schedule's attempts and the retry budget, and nothing
    /// unsafe to repeat is asked again (an unkeyed `POST` is not). When the
    /// attempts run out while the closure still asks for another, the call
    /// fails with ``HTTPError/status(_:excerpt:retryAfter:attempts:)`` for the
    /// last response, whatever its status. A call can pass its own through
    /// ``HTTPOverrides``.
    public var retryOnResponse: (@Sendable (HTTPResponse) -> RetryDecision?)?

    /// The circuit breaker kept for each host; `nil` for none. Default: opens
    /// when half of at least 20 calls in the last minute failed. Its
    /// `recordWhen` is replaced: the client decides what counts (5xx,
    /// timeouts and transport failures, never a 4xx).
    public var breaker: CircuitBreaker.Configuration?

    /// The rate at which requests may be sent to one host, as a token bucket
    /// kept for each host (``HTTPRateLimit``); `nil` (the default) for none.
    /// Every attempt takes a permit, retries included. A request waits for
    /// its turn, in order, unless the wait would outlast the caller's
    /// deadline or the queue is full: then it is refused at once with
    /// `.rejected(rate_limited)`, carrying how long to wait.
    public var rateLimit: HTTPRateLimit?

    /// The most requests in flight to one host; `nil` for no limit.
    /// Default 8.
    public var maxConcurrentPerHost: Int?

    /// The requests that may wait for a slot when ``maxConcurrentPerHost``
    /// are in flight; the next is refused with `bulkhead_full`. Default 64:
    /// a screen that starts 30 downloads should wait its turn, not fail.
    public var queueLimitPerHost: Int

    /// The most body bytes read from one response. Default 10 MB.
    public var maxResponseBytes: Int

    /// The most redirects one request follows. Default 10: an API needs one
    /// or two (a moved path, a trailing slash), and a longer chain is a loop
    /// or a misconfiguration, each hop a round trip of the caller's time.
    /// The next is ``HTTPError/redirectRefused(_:status:location:attempts:)``
    /// with `limit`; 0 follows none.
    ///
    /// The client follows redirects itself, not the transport, so the rules
    /// are the same everywhere: an `https` request never follows a redirect
    /// to `http`; once a redirect leaves the request's origin (scheme, host
    /// and port), the client's headers, the request's credentials and its
    /// idempotency key stay behind; a `POST` answered 301, 302 or 303 is
    /// followed as a `GET` without its body, and 307 or 308 keep the method
    /// and body (design/19).
    public var maxRedirects: Int

    /// How responses are decoded by ``HTTPClient/send(_:idempotencyKey:decoding:options:)``;
    /// a call can pass its own. `nil` (the default) means strict decoding of
    /// strict JSON, with the parser's input, string and container limits
    /// raised to what a response of ``maxResponseBytes`` can legitimately
    /// hold, so that a response the client was willing to read is not refused
    /// by the decoder for being over 8 MiB, for one string over 1 MiB, or for
    /// an array of over 100,000 elements. (Limits are only raised, never
    /// lowered; the depth limit stays.) Set a value to use it exactly as
    /// given, limits included.
    ///
    /// Unknown keys are not an option here: each object schema carries its
    /// own ``UnknownKeyPolicy``, and the default (`warn`) ignores a field the
    /// server added; a schema declared `reject` rejects it.
    public var decodeOptions: DecodeOptions?

    /// How much of an error response's body is kept in
    /// ``HTTPError/status(_:excerpt:retryAfter:attempts:)``. Default 512.
    public var errorExcerptBytes: Int

    /// Whether identical `GET`s in flight at once share one request. Identical
    /// means the same URL and the same headers (see
    /// ``ignoreHeadersForCoalescing``). Default `true`.
    public var coalesceGETs: Bool

    /// Headers left out of what makes two `GET`s identical. Two requests are
    /// shared only if they agree on the name and value of every other header,
    /// custom ones included, so callers with different credentials never share
    /// a response. List the noise that differs per call and changes nothing in
    /// the answer (`X-Request-Id`, `traceparent`); matching is
    /// case-insensitive. Default: none.
    public var ignoreHeadersForCoalescing: [String]

    /// The current wall-clock time, used only to turn an HTTP-date
    /// `Retry-After` into a wait. (The wait itself runs on the ambient
    /// clock.) Tests pin it.
    public var wallClock: @Sendable () -> Date

    public init(
        attemptTimeout: Duration = .seconds(10),
        schedule: BoundedSchedule = HTTPPolicy.standardSchedule,
        retryBudget: RetryBudget = RetryBudget(),
        retryStatuses: Set<Int> = HTTPPolicy.defaultRetryStatuses,
        maxRetryAfter: Duration = .seconds(60),
        breaker: CircuitBreaker.Configuration? = HTTPPolicy.standardBreaker,
        maxConcurrentPerHost: Int? = 8,
        queueLimitPerHost: Int = 64,
        rateLimit: HTTPRateLimit? = nil,
        maxResponseBytes: Int = 10_000_000,
        maxRedirects: Int = 10,
        errorExcerptBytes: Int = 512,
        decodeOptions: DecodeOptions? = nil,
        coalesceGETs: Bool = true,
        ignoreHeadersForCoalescing: [String] = [],
        retryOnResponse: (@Sendable (HTTPResponse) -> RetryDecision?)? = nil,
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(attemptTimeout > .zero, "an attempt needs a positive timeout")
        precondition(maxResponseBytes >= 0 && errorExcerptBytes >= 0, "byte limits cannot be negative")
        precondition(maxConcurrentPerHost.map { $0 >= 1 } ?? true, "a host needs room for at least one request")
        precondition(queueLimitPerHost >= 0, "a queue cannot have a negative size")
        precondition(maxRedirects >= 0, "a redirect limit cannot be negative")
        self.attemptTimeout = attemptTimeout
        self.schedule = schedule
        self.retryBudget = retryBudget
        self.retryStatuses = retryStatuses
        self.maxRetryAfter = maxRetryAfter
        self.breaker = breaker
        self.rateLimit = rateLimit
        self.maxConcurrentPerHost = maxConcurrentPerHost
        self.queueLimitPerHost = queueLimitPerHost
        self.maxResponseBytes = maxResponseBytes
        self.maxRedirects = maxRedirects
        self.errorExcerptBytes = errorExcerptBytes
        self.decodeOptions = decodeOptions
        self.coalesceGETs = coalesceGETs
        self.ignoreHeadersForCoalescing = ignoreHeadersForCoalescing
        self.retryOnResponse = retryOnResponse
        self.wallClock = wallClock
    }

    /// The defaults described on each field: 10 s per attempt; 3 attempts
    /// with jittered exponential backoff from 200 ms, capped at 10 s, drawing
    /// on a retry budget; a breaker that opens after half of at least 20
    /// calls fail; at most 8 requests in flight to one host; at most 10
    /// redirects followed.
    ///
    /// A new value each time, so each client gets its own retry budget.
    public static var standard: HTTPPolicy { HTTPPolicy() }

    public static let standardSchedule: BoundedSchedule =
        Schedule.exponential(base: .milliseconds(200)).capped(at: .seconds(10)).jittered().attempts(3)

    public static let standardBreaker = CircuitBreaker.Configuration(minimumCalls: 20, failureRateThreshold: 0.5)

    public static let defaultRetryStatuses: Set<Int> = [408, 429, 500, 502, 503, 504]
}

extension HTTPPolicy {
    /// The options a response is decoded with when the call names none.
    var responseDecodeOptions: DecodeOptions {
        if let decodeOptions { return decodeOptions }
        var options = DecodeOptions.strict
        // Raise the parser's limits to what a response of `maxResponseBytes`
        // can legitimately hold, as `maxBytes` is raised to it. A string
        // cannot be longer than the body; an array cannot have more elements
        // than two bytes each (`0,`) allow, nor an object more members than
        // five (`"":0,`). The limits stop a small document from costing a
        // lot; the client's byte limit already bounds how big this one is.
        options.parse.maxBytes = max(options.parse.maxBytes, maxResponseBytes)
        options.parse.maxStringBytes = max(options.parse.maxStringBytes, maxResponseBytes)
        options.parse.maxContainerCount = max(options.parse.maxContainerCount, maxResponseBytes / 2 + 1)
        return options
    }
}

/// How fast requests may be sent to one host: a token bucket.
///
/// The bucket holds up to ``burst`` permits and gains ``rate`` permits per
/// ``interval``; it starts full, so a quiet app can send a burst and then
/// settles to the steady rate. It is a Stoic ``RateLimiter`` per host, on the
/// ambient clock in force when the host is first used, so a test's clock
/// decides when permits come back.
public struct HTTPRateLimit: Sendable, Hashable {
    /// Permits added per ``interval``. At least 1.
    public var rate: Int
    /// The period ``rate`` is measured over. Positive.
    public var interval: Duration
    /// The bucket's size; `nil` for one interval's worth (``rate``).
    public var burst: Int?
    /// The most requests that may wait for a permit (default 100); past it a
    /// request is refused with `.rejected(rate_limited)`. There is no
    /// unbounded setting: a caller without a deadline would otherwise wait
    /// behind every other for as long as the queue grows (DESIGN.md,
    /// principle 2).
    public var queueLimit: Int

    public init(rate: Int, per interval: Duration = .seconds(1), burst: Int? = nil, queueLimit: Int = 100) {
        precondition(rate >= 1, "a rate limit needs a rate of at least one request")
        precondition(interval > .zero, "a rate limit's interval must be positive")
        precondition(burst.map { $0 >= 1 } ?? true, "a rate limit's burst must be at least one request")
        precondition(queueLimit >= 0, "a rate limit's queue cannot have a negative size")
        self.rate = rate
        self.interval = interval
        self.burst = burst
        self.queueLimit = queueLimit
    }
}
