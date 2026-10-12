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

    /// The circuit breaker kept for each host; `nil` for none. Default: opens
    /// when half of at least 20 calls in the last minute failed. Its
    /// `recordWhen` is replaced: the client decides what counts (5xx,
    /// timeouts and transport failures, never a 4xx).
    public var breaker: CircuitBreaker.Configuration?

    /// The most requests in flight to one host; `nil` for no limit.
    /// Default 8.
    public var maxConcurrentPerHost: Int?

    /// The requests that may wait for a slot when ``maxConcurrentPerHost``
    /// are in flight; the next is refused with `bulkhead_full`. Default 64:
    /// a screen that starts 30 downloads should wait its turn, not fail.
    public var queueLimitPerHost: Int

    /// The most body bytes read from one response. Default 10 MB.
    public var maxResponseBytes: Int

    /// How responses are decoded by ``HTTPClient/send(_:idempotencyKey:decoding:options:)``;
    /// a call can pass its own. `nil` (the default) means strict decoding of
    /// strict JSON, with the parser's input limit raised to
    /// ``maxResponseBytes`` so that a response the client was willing to read
    /// is not refused by the decoder for being over 8 MiB. Set a value to
    /// use it exactly as given, limits included.
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
        maxResponseBytes: Int = 10_000_000,
        errorExcerptBytes: Int = 512,
        decodeOptions: DecodeOptions? = nil,
        coalesceGETs: Bool = true,
        ignoreHeadersForCoalescing: [String] = [],
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(attemptTimeout > .zero, "an attempt needs a positive timeout")
        precondition(maxResponseBytes >= 0 && errorExcerptBytes >= 0, "byte limits cannot be negative")
        precondition(maxConcurrentPerHost.map { $0 >= 1 } ?? true, "a host needs room for at least one request")
        precondition(queueLimitPerHost >= 0, "a queue cannot have a negative size")
        self.attemptTimeout = attemptTimeout
        self.schedule = schedule
        self.retryBudget = retryBudget
        self.retryStatuses = retryStatuses
        self.maxRetryAfter = maxRetryAfter
        self.breaker = breaker
        self.maxConcurrentPerHost = maxConcurrentPerHost
        self.queueLimitPerHost = queueLimitPerHost
        self.maxResponseBytes = maxResponseBytes
        self.errorExcerptBytes = errorExcerptBytes
        self.decodeOptions = decodeOptions
        self.coalesceGETs = coalesceGETs
        self.ignoreHeadersForCoalescing = ignoreHeadersForCoalescing
        self.wallClock = wallClock
    }

    /// The defaults described on each field: 10 s per attempt; 3 attempts
    /// with jittered exponential backoff from 200 ms, capped at 10 s, drawing
    /// on a retry budget; a breaker that opens after half of at least 20
    /// calls fail; at most 8 requests in flight to one host.
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
        options.parse.maxBytes = max(options.parse.maxBytes, maxResponseBytes)
        return options
    }
}
