import Foundation
import Stoic
import StoicHTTP
import StoicJSON
import StoicTesting
import Testing

/// Many callers, a flaky server and a seeded scheduler: whatever the
/// interleaving, the client never makes more requests than its policy allows,
/// never repeats a request that is not safe to repeat, and never lets a
/// request reach the host without its key.
@Suite("HTTP under simulation")
struct HTTPSimulationTests {
    enum Outcome: Sendable {
        case ok
        case http(HTTPError)
        case cancelled
        case other(String)
    }

    static func run(_ api: HTTPClient, _ request: HTTPRequest, key: IdempotencyKey? = nil, deadline: Duration? = nil) async -> Outcome {
        do {
            if let deadline {
                _ = try await withTimeout(deadline) { try await api.send(request, idempotencyKey: key) }
            } else {
                _ = try await api.send(request, idempotencyKey: key)
            }
            return .ok
        } catch let error as HTTPError {
            return .http(error)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .other("\(error)")
        }
    }

    static let manyCallers: @Sendable (SimulationContext) async throws -> Void = { sim in
            let transport = ScriptedTransport()
            transport.on(.get("/a"), respond: [.status(503), Step.status(200).after(.milliseconds(50))])
            transport.on(.get("/b"), respond: [.failure(.networkConnectionLost), .hang, .status(200)])
            transport.on(.post("/orders", json: [:]), respond: [.status(503), .status(504), .status(200)])
            transport.on(.post("/pay", json: [:]), respond: [.status(503), .hang, .status(200)])
            let policy = HTTPPolicy(
                attemptTimeout: .seconds(1),
                schedule: Schedule.exponential(base: .milliseconds(100)).jittered().attempts(3),
                breaker: .init(minimumCalls: 6, failureRateThreshold: 0.5),
                maxConcurrentPerHost: 4,
                queueLimitPerHost: 8
            )
            let api = HTTPClient(base: URL(string: "https://api.example.com")!, policy: policy, transport: transport)
            let keys = (0..<3).map { _ in IdempotencyKey.random() }

            let outcomes = await withTaskGroup(of: Outcome.self) { group in
                for _ in 0..<5 { group.addTask { await Self.run(api, .get("/a")) } }
                for _ in 0..<2 { group.addTask { await Self.run(api, .get("/a"), deadline: .milliseconds(300)) } }
                for _ in 0..<3 { group.addTask { await Self.run(api, .get("/b")) } }
                for index in 0..<3 { group.addTask { await Self.run(api, .post("/orders", json: ["n": .number(JSONNumber(index))])) } }
                for index in 0..<3 { group.addTask { await Self.run(api, .post("/pay", json: ["n": .number(JSONNumber(index))]), key: keys[index]) } }
                group.addTask {
                    // A caller cancelled 50 ms in. Structured, so it runs on the simulation's executor
                    // (an unstructured Task would not, and the run would no longer replay).
                    await withTaskGroup(of: Outcome?.self) { inner in
                        inner.addTask { await Self.run(api, .get("/b")) }
                        inner.addTask {
                            // stoic:allow(discarded-try): the sleep only paces the cancellation
                            try? await Ambient.sleep(for: .milliseconds(50))
                            return nil
                        }
                        var result = Outcome.cancelled
                        for await next in inner {
                            if let next { result = next } else { inner.cancelAll() }
                        }
                        return result
                    }
                }
                var all: [Outcome] = []
                for await outcome in group { all.append(outcome) }
                return all
            }

            for outcome in outcomes {
                if case .other(let text) = outcome { Issue.record("an error that is not an HTTPError: \(text)") }
            }
            try #require(outcomes.count == 17)

            // An unkeyed POST is sent at most once, ever: every body is distinct and none repeats.
            let orders = transport.requests(to: .post("/orders", json: [:]))
            try #require(orders.count <= 3)
            try #require(Set(orders.compactMap(\.body)).count == orders.count, "an unkeyed POST was repeated")
            try #require(orders.allSatisfy { !$0.headers.contains("Idempotency-Key") })

            // A keyed POST carries its key on every attempt, with the same body, at most three times.
            let payments = transport.requests(to: .post("/pay", json: [:]))
            for key in keys {
                let mine = payments.filter { $0.headers["Idempotency-Key"] == key.rawValue }
                try #require(mine.count <= 3)
                try #require(Set(mine.compactMap(\.body)).count <= 1, "one operation, one body")
            }
            try #require(payments.allSatisfy { request in keys.contains { $0.rawValue == request.headers["Idempotency-Key"] } })

            // Retries are bounded: no call makes more than three attempts, shared or not.
            try #require(transport.requests(to: .get("/a")).count <= 7 * 3)
            try #require(transport.requests(to: .get("/b")).count <= 4 * 3)
            try #require(transport.maxInFlightCount <= 4, "the bulkhead held")
            try #require(transport.unscriptedRequests.isEmpty)
    }

    @Test func requestsAreBoundedByThePolicyAndUnsafeOnesAreNeverRepeated() async throws {
        try await simulate(seeds: 0..<300, Self.manyCallers)
    }

    /// Eight callers ask for the same avatar. Under the full portfolio (PCT schedules, early timers,
    /// injected delays) a caller may arrive after the response has landed, so the number of requests is
    /// not fixed, but the invariant is: identical GETs are never in flight twice, and every caller either
    /// started a request or shared one.
    @Sendable static func eightIdenticalGets(_ sim: SimulationContext) async throws -> Int {
        let transport = ScriptedTransport()
        transport.on(.get("/avatar"), respond: [Step.bytes([9]).after(.milliseconds(20))])
        let api = HTTPClient(base: URL(string: "https://api.example.com")!, policy: .standard, transport: transport)
        let results = await withTaskGroup(of: Outcome.self) { group in
            for _ in 0..<8 { group.addTask { await Self.run(api, .get("/avatar")) } }
            var all: [Outcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        try #require(results.count == 8)
        try #require(results.allSatisfy { if case .ok = $0 { true } else { false } })
        try #require(transport.maxInFlightCount == 1, "the same GET was in flight twice")
        try #require(transport.requestCount >= 1)
        // An early timer can fire the attempt's 10 s timeout before the 20 ms response is due, and the
        // attempt is retried: a retry is another request for the same caller, not another caller.
        let shared = sim.events.count("http.coalesced")
        let started = transport.requestCount - sim.events.count("http.retry")
        try #require(shared + started == 8, "\(shared) shared + \(started) started != 8 callers")
        return started
    }

    @Test func identicalGetsAreNeverInFlightTwiceAndEveryCallerSharesOrStarts() async throws {
        try await simulate(seeds: 0..<300) { sim in _ = try await Self.eightIdenticalGets(sim) }
    }

    /// With one uniformly chosen schedule and no injected delays, time passes only when everything is
    /// asleep, so all eight callers have joined before the 20 ms response can land: exactly one request.
    /// (This holds only there: a PCT schedule or an early timer can land the response first.)
    @Test func withNoTimeToSpareTheyShareExactlyOneRequest() async throws {
        try await simulate(seeds: 0..<150, faults: .none, schedule: .uniform) { sim in
            let requests = try await Self.eightIdenticalGets(sim)
            try #require(requests == 1, "eight callers, \(requests) requests")
            try #require(sim.events.count("http.retry") == 0)
        }
    }

    typealias Step = ScriptedTransport.Step
}
