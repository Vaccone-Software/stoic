internal import Foundation
internal import Stoic
internal import Synchronization

/// What the client knows about a request once it has been resolved against
/// the base URL and given its final headers.
struct PreparedRequest: Sendable {
    /// The request as the transport will see it: an absolute URL, the query
    /// folded in, every header (default ones and the idempotency key too).
    var request: HTTPRequest
    /// The URL's host, as events report it.
    var host: String
    /// The key per-host state is kept under: the host, and the port if the
    /// URL names one.
    var hostKey: String
    var path: String
    /// The query string, which events record only as a private field.
    var query: String?
    var safeToRepeat: Bool
    /// What the call changed about the policy.
    var overrides: HTTPOverrides
    /// The request as the caller gave it (or, after a redirect, as the
    /// redirect made it), and its key, to prepare again with fresh
    /// credentials and to derive the next hop from.
    var source: HTTPRequest
    var sourceKey: IdempotencyKey?
    /// The credentials generation the request was prepared with.
    var generation: Int
    /// Whether the client's own headers may go into the request at all: not
    /// once a redirect chain has left the base URL's origin.
    var clientHeadersAllowed: Bool
    /// Whether the client's own headers went into the request (it is for the
    /// base URL's origin), which is what makes a `401` the client's to repair.
    var carriesClientHeaders: Bool

    /// The fields every event about this request carries: method, host and
    /// path are public; nothing else about the request is recorded.
    var fields: [Event.Field] {
        [
            .init("method", .string(request.method.rawValue), privacy: .public),
            .init("host", .string(host), privacy: .public),
            .init("path", .string(path), privacy: .public),
        ]
    }
}

/// What a call wants of the response body.
enum BodyMode: Sendable {
    /// The whole body, in memory, under the policy's `maxResponseBytes`.
    case buffered
    /// The head, and the body as a stream of at most `limit` bytes. The
    /// statuses in `accepted` are returned as responses rather than failures,
    /// for a caller that interprets them itself (a `416`).
    case streamed(limit: Int, accepted: Set<Int>)
}

/// Whether a response will transfer a body, which is the only length a byte
/// limit may refuse before the first byte.
///
/// RFC 9110: a response to `HEAD` never includes content, and neither does
/// `204` (No Content) or `304` (Not Modified). The `Content-Length` on those
/// responses is the size a `GET` of the same resource would have sent — what
/// a caller sends `HEAD` to learn — so treating it as a body over the limit
/// discards the headers that were the point of the request. A body that
/// arrives anyway is still counted by whoever reads the bytes.
enum ResponseBody {
    static func willBeTransferred(method: HTTPMethod, status: Int) -> Bool {
        if method == .head { return false }
        switch status {
        case 204, 304: return false
        default: return true
        }
    }
}

/// What one attempt brought back: the response, whose body is empty when it
/// is streamed, and the body still to be read in that case.
struct Received: Sendable {
    var response: HTTPResponse
    var stream: HTTPBodyStream?
}

/// A response with the number of requests it took, and what an event about
/// it says of the request that earned it.
struct Delivered: Sendable {
    var response: HTTPResponse
    /// The body of a streamed response, still to be read.
    var stream: HTTPBodyStream?
    var attempts: Int
    /// The label and fields of the request the response answers: the last
    /// hop's, after any redirect.
    var label: String
    var fields: [Event.Field]
}

/// The client's hold on a streamed body: what a transport delivers, counted
/// against the limit and reported as the client reports everything else.
///
/// A transport that honours the limit has stopped at it; the count is for one
/// that does not (the client checks the size of a buffered response again for
/// the same reason). What the transport throws (`URLError`, its own
/// ``HTTPTransportError``) reaches the caller as ``HTTPError``, the
/// cancellation of the caller as `CancellationError`, and the passing of the
/// caller's deadline as `.rejected(deadline_exceeded)`, which is what `send`
/// answers in each case. Nothing here retries: bytes the caller has taken
/// cannot be sent again.
final class GuardedBody: Sendable {
    private let source: HTTPBodyStream
    private let limit: Int
    private let attempts: Int
    private let label: String
    private let fields: [Event.Field]
    private let received = Mutex(0)
    /// Whether the caller abandoned the body: what the transport then throws
    /// (`URLError.cancelled`, say) is the caller's own doing, so it reads
    /// `CancellationError`, not a transport failure.
    private let abandoned = Mutex(false)

    init(_ source: HTTPBodyStream, limit: Int, attempts: Int, label: String, fields: [Event.Field]) {
        self.source = source
        self.limit = limit
        self.attempts = attempts
        self.label = label
        self.fields = fields
    }

    /// The stream the caller reads: this body's, with the source's lifetime.
    var stream: HTTPBodyStream {
        HTTPBodyStream(next: { try await self.next() }, cancel: {
            self.abandoned.withLock { $0 = true }
            self.source.cancel()
        })
    }

    private func next() async throws -> [UInt8]? {
        let chunk: [UInt8]?
        do {
            chunk = try await source.read()
        } catch {
            throw failure(for: error)
        }
        guard let chunk else { return nil }
        let total = received.withLock { count -> Int in
            count += chunk.count
            return count
        }
        if total > limit {
            source.cancel()
            throw tooLarge()
        }
        return chunk
    }

    private func tooLarge() -> HTTPError {
        Ambient.record(Event("http.response_too_large", level: .warning, label: label, fields: fields + [.init("limit", .int(limit))]))
        return .responseTooLarge(limit: limit, attempts: attempts)
    }

    private func failure(for error: any Error) -> any Error {
        if let error = error as? HTTPError { return error }
        if abandoned.withLock({ $0 }) { return CancellationError() }
        switch AttemptError(classifying: error) {
        case .cancelled:
            if CancellationCause.current == .deadline || Deadline.current?.hasPassed == true {
                return HTTPError.rejected(Rejection(.deadlineExceeded, label: label), attempts: attempts)
            }
            return CancellationError()
        case .tooLarge:
            return tooLarge()
        case .timedOut:
            return HTTPError.timedOut(attempt: attempts)
        case .transport(let code):
            return HTTPError.transport(code, attempts: attempts)
        case .status:
            // A body carries no status; a transport that says so is saying it failed.
            return HTTPError.transport(.unknown, attempts: attempts)
        }
    }
}

/// The breaker, rate limiter and bulkhead the client keeps for one host.
final class HostState: Sendable {
    let label: String
    let breaker: CircuitBreaker?
    let limiter: RateLimiter?
    let bulkhead: Bulkhead?

    init(label: String, breaker: CircuitBreaker?, limiter: RateLimiter?, bulkhead: Bulkhead?) {
        self.label = label
        self.breaker = breaker
        self.limiter = limiter
        self.bulkhead = bulkhead
    }
}

/// The headers the reauthentication hook last returned, and how many times it
/// has returned: a request prepared before a refresh knows, by its generation,
/// that the refresh has already happened.
struct Credentials: Sendable {
    var generation = 0
    var headers = HTTPHeaders()
}

/// Why the reauthentication hook did not produce credentials.
struct ReauthenticationFailure: Error, Sendable {
    /// The type of the hook's error, for the event; never its text.
    var kind: String
}

/// The hosts a client has talked to, bounded: a client that follows
/// absolute URLs to arbitrary hosts forgets the least recently used rather
/// than grow without limit, so a busy host's breaker survives a flood of
/// one-off hosts.
///
/// A host with a request in flight is never forgotten. Its bulkhead is what
/// bounds the requests to it: one made afresh while the old one still holds
/// slots would let a second set through, and a fresh breaker would forget
/// what the old one was learning. So the table holds at most ``limit`` hosts
/// plus however many more are in use at that moment, and gives the excess
/// back as their requests end.
struct HostTable {
    static let limit = 256

    private struct Entry {
        var state: HostState
        /// Requests running through this host's policies now.
        var leases: Int
    }

    private var hosts: [String: Entry] = [:]
    /// Keys from least to most recently used.
    private var order: [String] = []

    /// The hosts known now.
    var count: Int { hosts.count }

    /// The state for `key`, without counting as a use.
    func existing(_ key: String) -> HostState? { hosts[key]?.state }

    /// The state for `key` (made by `make` if the host is new), marked as
    /// just used and as in use until ``release(_:)``.
    mutating func lease(_ key: String, orMake make: () -> HostState) -> HostState {
        let state = hosts[key]?.state ?? make()
        hosts[key] = Entry(state: state, leases: (hosts[key]?.leases ?? 0) + 1)
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
        evict()
        return state
    }

    /// Ends one request's use of `key`.
    mutating func release(_ key: String) {
        hosts[key]?.leases -= 1
        evict()
    }

    /// Forgets the least recently used hosts that are idle until the table is
    /// within its limit, or only hosts in use are left over it.
    private mutating func evict() {
        var index = 0
        while order.count > Self.limit, index < order.count {
            let key = order[index]
            if hosts[key]?.leases == 0 {
                hosts[key] = nil
                order.remove(at: index)
            } else {
                index += 1
            }
        }
    }
}

/// How many attempts reached the transport, and when the last one ended:
/// what `http.retry` reports and what an error says about attempts made.
/// A redirect's next request is an attempt (it reached the transport) but
/// not a retry.
final class AttemptLog: Sendable {
    private struct State {
        var count = 0
        /// Attempts since the last redirect was followed.
        var sinceHop = 0
        var lastEnd: AnyClock.Instant?
        var lastReason = ""
    }

    private let state = Mutex(State())

    var count: Int { state.withLock { $0.count } }

    /// Starts an attempt; returns its number, whether it is a retry, and, for
    /// a retry, the time since the previous attempt ended and why that one
    /// failed.
    func begin(at now: AnyClock.Instant) -> (number: Int, retry: Bool, gap: Duration?, previous: String) {
        state.withLock { state in
            state.count += 1
            state.sinceHop += 1
            let retry = state.sinceHop > 1
            let gap = state.lastEnd.map { $0.duration(to: now) }
            return (state.count, retry, retry ? gap : nil, state.lastReason)
        }
    }

    /// Notes that a redirect is being followed: the next attempt is its
    /// first, not a retry of the last.
    func hop() {
        state.withLock { $0.sinceHop = 0 }
    }

    func end(at now: AnyClock.Instant, reason: String) {
        state.withLock { state in
            state.lastEnd = now
            state.lastReason = reason
        }
    }
}

/// Sits between the retry stage and the event sink to learn *why* a retry
/// stopped. `retry` rethrows the last error whatever the reason; the client
/// wants to report a spent budget and a wait that would outlast the deadline
/// as the rejections they are, and the retry's own events are the one place
/// that says so. Everything is forwarded unchanged.
final class RetryWatcher: Instrumentation {
    private struct State {
        var budgetExhausted = false
        var deadlineSkip: Duration?
    }

    private let inner: any Instrumentation
    private let label: String
    private let state = Mutex(State())

    init(forwardingTo inner: any Instrumentation, label: String) {
        self.inner = inner
        self.label = label
    }

    /// Whether the retry stopped because its budget had no token.
    var budgetExhausted: Bool { state.withLock { $0.budgetExhausted } }

    /// The wait the retry declined to start because it would outlast the
    /// deadline, if that is why it stopped.
    var deadlineSkip: Duration? { state.withLock { $0.deadlineSkip } }

    func record(_ event: Event) {
        if event.label == label {
            switch event.name.rawValue {
            case "retry.budget_exhausted":
                state.withLock { $0.budgetExhausted = true }
            case "retry.deadline_skip":
                if case .duration(let delay)? = event["delay"] { state.withLock { $0.deadlineSkip = delay } }
            default:
                break
            }
        }
        inner.record(event)
    }

    func isEnabled(_ level: Event.Level) -> Bool {
        inner.isEnabled(level)
    }
}

/// Whether the operation in a coalesced flight was run by this caller.
final class LedFlag: Sendable {
    private let led = Mutex(false)
    func mark() { led.withLock { $0 = true } }
    var value: Bool { led.withLock { $0 } }
}

/// What makes two `GET`s the same request: the URL and every header, names
/// lowercased and sorted, except the ones the policy says to ignore. A header
/// the library has never heard of (`X-API-Key`) can change the response as
/// surely as `Authorization`, so the key errs on the side of not sharing.
struct FlightKey: Hashable, Sendable {
    var url: String
    var headers: [String]
    /// What else makes a pipeline behave differently: the overrides that can
    /// be compared, so a call with a longer timeout does not join a flight
    /// that will cut it short. Kept as values, not hashes: two schedules can
    /// share a hash, and a call must never run on another's schedule.
    var attemptTimeout: Duration?
    var schedule: BoundedSchedule?
    var bypassBreaker: Bool
    var reauthenticate: Bool

    init(_ request: HTTPRequest, ignoring ignored: [String], overrides: HTTPOverrides = .none) {
        url = request.url?.absoluteString ?? ""
        attemptTimeout = overrides.attemptTimeout
        schedule = overrides.schedule
        bypassBreaker = overrides.bypassBreaker
        reauthenticate = overrides.reauthenticate
        let skipped = Set(ignored.map { $0.lowercased() })
        headers = request.headers.fields
            .map { (name: $0.name.lowercased(), value: $0.value) }
            .filter { !skipped.contains($0.name) }
            .map { "\($0.name)\u{0}\($0.value)" }
            .sorted()
    }
}

/// A coalesced flight's failure, with the deadline of the caller who started
/// it, so a caller who joined with more time can tell whose deadline ended it.
struct FlightFailure: Error, Sendable {
    var error: HTTPError
    var starterDeadline: AnyClock.Instant?
}
