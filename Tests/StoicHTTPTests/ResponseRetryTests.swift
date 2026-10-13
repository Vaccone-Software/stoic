import Foundation
import Stoic
@testable import StoicHTTP
import StoicJSON
import StoicTesting
import Testing

/// Retrying on what came back, not only on what was thrown.
@Suite("HTTP retry on a response")
struct HTTPResponseRetryTests {
    private static let pollAccepted: @Sendable (HTTPResponse) -> RetryDecision? = { response in
        response.status == 202 ? .retry : nil
    }

    // Row: a 2xx response says to ask again.
    @Test(.failureMode("design/19", "a 2xx response says to ask again"))
    func aSuccessThePredicateCallsUnfinishedIsAskedAgainAfterItsRetryAfter() async throws {
        try await withRig(.testing(retryOnResponse: Self.pollAccepted)) { (rig) async throws in
            rig.transport.on(.get("/job/1"), respond: [
                .status(202, headers: ["Retry-After": "3"]), .status(202), .json(#"{"done": true}"#),
            ])
            let task = rig.start(.get("/job/1"))
            await rig.waitForBackoff(1)
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(3))], "the server's 3 s, not the schedule's 1 s")
            await rig.clock.advance(by: .seconds(3))
            await rig.waitForBackoff(2)
            await rig.clock.advance(by: .seconds(2))
            let response = try await task.value
            #expect(response.status == 200)
            #expect(rig.transport.requestCount == 3)
            #expect(rig.events.events(named: "http.retry").map { $0.text("reason") } == ["status_202", "status_202"])
        }
    }

    @Test func theRetryAfterOfAnAskedAgainResponseIsCapped() async throws {
        try await withRig(.testing(retryOnResponse: Self.pollAccepted)) { (rig) async throws in
            rig.transport.on(.get("/job/1"), respond: [.status(202, headers: ["Retry-After": "86400"]), .status(200)])
            let task = rig.start(.get("/job/1"))
            await rig.waitForBackoff(1)
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(60))], "HTTPPolicy.maxRetryAfter")
            await rig.clock.advance(by: .seconds(60))
            #expect(try await task.value.status == 200)
        }
    }

    @Test func anExplicitWaitFromThePredicateIsUsedAndCapped() async throws {
        let policy = HTTPPolicy.testing(retryOnResponse: { response in
            switch response.headers["X-Wait"] {
            case "short": .retryAfter(.seconds(7))
            case "long": .retryAfter(.seconds(3600))
            default: nil
            }
        })
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.get("/short"), respond: [.status(200, headers: ["X-Wait": "short"]), .status(200)])
            rig.transport.on(.get("/long"), respond: [.status(200, headers: ["X-Wait": "long"]), .status(200)])
            let short = rig.start(.get("/short"))
            await rig.waitForBackoff(1)
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(7))])
            await rig.clock.advance(by: .seconds(7))
            _ = try await short.value
            let long = rig.start(.get("/long"))
            await rig.waitForBackoff(2)
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(67))], "60 s from now")
            await rig.clock.advance(by: .seconds(60))
            _ = try await long.value
        }
    }

    @Test func stopMakesAStatusInTheRetrySetFinal() async throws {
        let policy = HTTPPolicy.testing(retryOnResponse: { response in
            response.headers["Retry-After"].flatMap(Int.init).map { $0 > 600 ? .stop : nil } ?? nil
        })
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.get("/down"), respond: [.status(503, headers: ["Retry-After": "3600"]), .status(200)])
            let error = await rig.httpError(of: rig.start(.get("/down")))
            guard case .status(503, _, let retryAfter, let attempts)? = error else {
                Issue.record("expected the 503 to be final, got \(String(describing: error))")
                return
            }
            #expect(retryAfter == .seconds(3600))
            #expect(attempts == 1)
            #expect(rig.transport.requestCount == 1)
            #expect(rig.clock.sleeperCount == 0)
        }
    }

    @Test func aPredicateThatDefersLeavesTheRetryStatusesInCharge() async throws {
        try await withRig(.testing(retryOnResponse: { _ in nil })) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503), .status(200)])
            rig.transport.on(.get("/b"), respond: [.status(404)])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
            #expect(await rig.httpError(of: rig.start(.get("/b"))) == .status(404, excerpt: "", retryAfter: nil, attempts: 1))
        }
    }

    @Test func aPredicateCanAskAgainAboutAClientErrorTheStatusSetWouldNotRetry() async throws {
        let policy = HTTPPolicy.testing(retryOnResponse: { $0.status == 409 ? .retry : nil })
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(409), .status(200)])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
        }
    }

    @Test func anUnkeyedPostThatWasAnsweredIsNotAskedAgain() async throws {
        let policy = HTTPPolicy.testing(retryOnResponse: { _ in .retry })
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.post("/orders", json: [:]), respond: [.status(201)])
            let response = try await rig.start(.post("/orders", json: [:])).value
            #expect(response.status == 201, "delivered, not turned into an error that cannot be retried")
            #expect(rig.transport.requestCount == 1)

            // With a key it can be asked again.
            rig.transport.on(.post("/keyed", json: [:]), respond: [.status(201), .status(201)])
            let keyed = rig.start(.post("/keyed", json: [:]), key: .random())
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            await rig.waitForBackoff(2)
            await rig.clock.advance(by: .seconds(2))
            _ = await rig.failure(of: keyed)
            #expect(rig.transport.requests(to: .post("/keyed", json: [:])).count == 3)
        }
    }

    @Test func whenTheAttemptsRunOutTheLastResponseIsTheStatusError() async throws {
        try await withRig(.testing(attempts: 2, retryOnResponse: Self.pollAccepted)) { (rig) async throws in
            rig.transport.on(.get("/job"), respond: [.status(202, body: "queued")])
            let task = rig.start(.get("/job"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(await rig.httpError(of: task) == .status(202, excerpt: "queued", retryAfter: nil, attempts: 2))
        }
    }

    @Test func aCallsOwnPredicateTakesThePlaceOfThePolicys() async throws {
        try await withRig(.testing(retryOnResponse: { _ in .stop })) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503), .status(200)])
            let task = rig.start(.get("/a"), overrides: HTTPOverrides(retryOnResponse: { _ in nil }))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
        }
    }
}
