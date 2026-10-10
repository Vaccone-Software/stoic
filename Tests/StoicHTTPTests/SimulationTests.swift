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

    @Test func requestsAreBoundedByThePolicyAndUnsafeOnesAreNeverRepeated() async throws {
        try await simulate(seeds: 0..<150) { sim in
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
                    let task = Task { await Self.run(api, .get("/b")) }
                    // stoic:allow(discarded-try): the sleep only paces the cancellation
                    try? await Ambient.sleep(for: .milliseconds(50))
                    task.cancel()
                    return await task.value
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
    }

    @Test func identicalGetsStartedTogetherShareOneRequest() async throws {
        try await simulate(seeds: 0..<150, faults: .none) { sim in
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
            try #require(transport.requestCount == 1, "eight callers, \(transport.requestCount) requests")
        }
    }

    typealias Step = ScriptedTransport.Step
}
