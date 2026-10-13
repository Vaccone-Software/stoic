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
    /// The request as the caller gave it, and its key, to prepare again with
    /// fresh credentials.
    var source: HTTPRequest
    var sourceKey: IdempotencyKey?
    /// The credentials generation the request was prepared with.
    var generation: Int
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

/// A response with the number of requests it took.
struct Delivered: Sendable {
    var response: HTTPResponse
    var attempts: Int
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
struct HostTable {
    static let limit = 256

    private var hosts: [String: HostState] = [:]
    /// Keys from least to most recently used.
    private var order: [String] = []

    /// The state for `key`, without counting as a use.
    func existing(_ key: String) -> HostState? { hosts[key] }

    /// The state for `key`, marked as just used.
    mutating func use(_ key: String) -> HostState? {
        guard let state = hosts[key] else { return nil }
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
        return state
    }

    mutating func insert(_ state: HostState, for key: String) {
        hosts[key] = state
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
        if order.count > Self.limit {
            hosts[order.removeFirst()] = nil
        }
    }
}

/// How many attempts reached the transport, and when the last one ended:
/// what `http.retry` reports and what an error says about attempts made.
final class AttemptLog: Sendable {
    private struct State {
        var count = 0
        var lastEnd: AnyClock.Instant?
        var lastReason = ""
    }

    private let state = Mutex(State())

    var count: Int { state.withLock { $0.count } }

    /// Starts an attempt; returns its number, and, for a retry, the time
    /// since the previous attempt ended and why that one failed.
    func begin(at now: AnyClock.Instant) -> (number: Int, gap: Duration?, previous: String) {
        state.withLock { state in
            state.count += 1
            let gap = state.lastEnd.map { $0.duration(to: now) }
            return (state.count, state.count > 1 ? gap : nil, state.lastReason)
        }
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
    /// that will cut it short.
    var variant: String

    init(_ request: HTTPRequest, ignoring ignored: [String], overrides: HTTPOverrides = .none) {
        url = request.url?.absoluteString ?? ""
        var variant: [String] = []
        if let timeout = overrides.attemptTimeout { variant.append("timeout=\(timeout)") }
        if let schedule = overrides.schedule { variant.append("schedule=\(schedule.hashValue)") }
        if overrides.bypassBreaker { variant.append("bypass") }
        if !overrides.reauthenticate { variant.append("noreauth") }
        self.variant = variant.joined(separator: ";")
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
