import Foundation
import Stoic
import StoicHTTP
import StoicSchema
import StoicTesting
import Testing

/// Polls `condition` until it holds, or fails the test after `timeout` of
/// real time. For waiting on work that runs on other tasks and needs no help
/// from the test; anything waiting on the virtual clock uses
/// `TestClock.waitForSleepers` instead.
func eventually(
    timeout: Duration = .seconds(10),
    _ message: @autoclosure () -> String = "the condition never became true",
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let limit = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now >= limit {
            Testing.Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
            return
        }
        // stoic:allow(discarded-try): a cancelled poll just checks the condition once more
        try? await clock.sleep(for: .milliseconds(1))
    }
}

extension RecordingInstrumentation {
    func count(_ name: EventName) -> Int { events(named: name).count }
}

extension Event {
    func text(_ key: String) -> String? {
        if case .string(let value)? = self[key] { value } else { nil }
    }

    func number(_ key: String) -> Int? {
        if case .int(let value)? = self[key] { value } else { nil }
    }

    func duration(_ key: String) -> Duration? {
        if case .duration(let value)? = self[key] { value } else { nil }
    }
}

let apiBase = URL(string: "https://api.example.com")!

// MARK: - A client on a script and a virtual clock

extension HTTPPolicy {
    /// The standard policy with a backoff a test can predict: 1 s, then 2 s.
    static func testing(
        attempts: Int = 3,
        timeout: Duration = .seconds(10),
        breaker: CircuitBreaker.Configuration? = HTTPPolicy.standardBreaker,
        maxConcurrent: Int? = 8,
        queueLimit: Int = 64,
        maxResponseBytes: Int = 10_000_000,
        retryBudget: RetryBudget = .unlimited,
        coalesce: Bool = true,
        rateLimit: HTTPRateLimit? = nil,
        retryOnResponse: (@Sendable (HTTPResponse) -> RetryDecision?)? = nil,
        wallClock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> HTTPPolicy {
        HTTPPolicy(
            attemptTimeout: timeout,
            schedule: Schedule.exponential(base: .seconds(1)).unjittered().attempts(attempts),
            retryBudget: retryBudget,
            breaker: breaker,
            maxConcurrentPerHost: maxConcurrent,
            queueLimitPerHost: queueLimit,
            rateLimit: rateLimit,
            maxResponseBytes: maxResponseBytes,
            coalesceGETs: coalesce,
            retryOnResponse: retryOnResponse,
            wallClock: wallClock
        )
    }
}

typealias Step = ScriptedTransport.Step
typealias Sending = Task<HTTPResponse, any Error>

/// A client, its scripted transport, a test clock and the events it recorded.
final class Rig: Sendable {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    let transport = ScriptedTransport()
    let api: HTTPClient

    init(policy: HTTPPolicy, headers: HTTPHeaders, reauthenticate: (@Sendable () async throws -> HTTPHeaders)? = nil) {
        api = HTTPClient(base: apiBase, policy: policy, transport: transport, headers: headers, reauthenticate: reauthenticate)
    }

    /// Starts a request on its own task, which inherits the test's ambient context.
    func start(_ request: HTTPRequest, key: IdempotencyKey? = nil, overrides: HTTPOverrides = .none) -> Sending {
        let api = api
        return Task { try await api.send(request, idempotencyKey: key, overrides: overrides) }
    }

    /// Waits until the `count`-th failed attempt is waiting out its backoff.
    func waitForBackoff(_ count: Int = 1) async {
        await eventually("backoff \(count) never began") { events.count("retry.attempt_failed") >= count }
        await clock.waitForSleepers(count: 1)
    }

    /// Waits until an attempt is hanging in the transport (which waits on no
    /// clock) and its timeout is running.
    /// `timers` counts what else sleeps on the clock at the same time: a
    /// caller's deadline is a timer of its own, and so is each stage that
    /// honours it.
    func waitForHangingAttempt(timers: Int = 0) async {
        await eventually("the attempt never reached the transport") { transport.inFlightCount >= 1 }
        await clock.waitForSleepers(count: 1 + timers)
    }

    /// The error a request ended with, or `nil` if it succeeded.
    func failure(of task: Sending) async -> (any Error)? {
        do {
            _ = try await task.value
            return nil
        } catch {
            return error
        }
    }

    func httpError(of task: Sending) async -> HTTPError? {
        await failure(of: task) as? HTTPError
    }

    /// The headers of every request the transport saw.
    var sentHeaders: [HTTPHeaders] { transport.requests.map(\.headers) }
}

func withRig<R>(
    _ policy: HTTPPolicy = .testing(),
    headers: HTTPHeaders = [:],
    reauthenticate: (@Sendable () async throws -> HTTPHeaders)? = nil,
    _ body: (Rig) async throws -> R
) async throws -> R {
    let rig = Rig(policy: policy, headers: headers, reauthenticate: reauthenticate)
    return try await withTestAmbient(clock: rig.clock, seed: 7, events: rig.events) { () async throws -> R in
        try await body(rig)
    }
}

struct User: Sendable, Equatable {
    var id = 0
    var name = ""

    static let schema = Schema.object(User.self, default: User()) {
        Field("id", \.id, .int(.range(1...1_000_000)))
        Field("name", \.name, .string(.length(0...40)))
    }
}

/// A body with a long string and a long array: the two things the parser's
/// per-string and per-container limits count.
struct Blob: Sendable, Equatable {
    var text = ""
    var values: [Int] = []

    static let schema = Schema.object(Blob.self, default: Blob()) {
        Field("text", \.text, .string())
        Field("values", \.values, .array(of: .int()))
    }
}
