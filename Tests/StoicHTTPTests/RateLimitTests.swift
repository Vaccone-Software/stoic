import Foundation
import Stoic
@testable import StoicHTTP
import StoicTesting
import Testing

/// The client-side token bucket, per host, on the ambient clock.
@Suite("HTTP rate limit")
struct HTTPRateLimitTests {
    private static let twoPerSecond = HTTPRateLimit(rate: 2, per: .seconds(1))

    private func waiters(_ rig: Rig) -> Int { rig.api.rateLimiter(forHost: "api.example.com")?.waiterCount ?? 0 }

    // Row: a host's rate limit is spent.
    @Test(.failureMode("design/19", "a host's rate limit is spent"))
    func aRequestOverTheBurstWaitsForItsPermit() async throws {
        try await withRig(.testing(rateLimit: Self.twoPerSecond)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [], then: .status(200))
            _ = try await rig.start(.get("/a")).value
            _ = try await rig.start(.get("/a?x=1")).value
            #expect(rig.transport.requestCount == 2, "the burst went straight through")
            #expect(rig.clock.now.offset == .zero)

            let third = rig.start(.get("/a?x=2"))
            await eventually { waiters(rig) == 1 }
            #expect(rig.transport.requestCount == 2)
            await rig.clock.advance(by: .milliseconds(499))
            #expect(rig.transport.requestCount == 2)
            await rig.clock.advance(by: .milliseconds(1))
            #expect(try await third.value.status == 200)
            #expect(rig.transport.requestCount == 3)
            #expect(rig.clock.now.offset == .milliseconds(500))
        }
    }

    @Test func requestsWaitInOrder() async throws {
        let limit = HTTPRateLimit(rate: 1, per: .seconds(1))
        try await withRig(.testing(rateLimit: limit)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [], then: .status(200))
            _ = try await rig.start(.get("/a?n=0")).value
            var tasks: [Sending] = []
            for number in 1...3 {
                tasks.append(rig.start(.get("/a?n=\(number)")))
                await eventually { waiters(rig) == number }
            }
            for second in 1...3 {
                await rig.clock.advance(by: .seconds(1))
                _ = try await tasks[second - 1].value
                #expect(rig.transport.requestCount == second + 1)
            }
            let queries = rig.transport.requests.compactMap { $0.url?.query }
            #expect(queries == ["n=0", "n=1", "n=2", "n=3"])
        }
    }

    @Test func everyAttemptTakesAPermitRetriesIncluded() async throws {
        let limit = HTTPRateLimit(rate: 1, per: .seconds(5))
        try await withRig(.testing(rateLimit: limit)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503), .status(200)])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))   // the backoff ends; the retry needs a permit
            await eventually { waiters(rig) == 1 }
            #expect(rig.transport.requestCount == 1)
            await rig.clock.advance(by: .seconds(4))
            #expect(try await task.value.status == 200)
            #expect(rig.transport.requestCount == 2)
            #expect(rig.clock.now.offset == .seconds(5))
        }
    }

    // Row: a request would wait longer than its deadline or the queue allows.
    @Test(.failureMode("design/19", "a request would wait longer than its deadline or the queue allows"))
    func aWaitThatOutlastsTheDeadlineOrFillsTheQueueIsARejectionAtOnce() async throws {
        let limit = HTTPRateLimit(rate: 1, per: .seconds(10), queueLimit: 1)
        try await withRig(.testing(rateLimit: limit)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [], then: .status(200))
            _ = try await rig.start(.get("/a")).value

            // The permit is 10 s away; the caller has 3.
            let api = rig.api
            let hurried = Task { try await withTimeout(.seconds(3)) { try await api.send(.get("/a?hurried")) } }
            let hurriedError = try #require(await rig.failure(of: hurried) as? HTTPError)
            let rejection = try #require(hurriedError.rejection)
            #expect(rejection.reason == .rateLimited)
            #expect(rejection.retryAfter == .seconds(10))
            #expect(hurriedError.attempts == 0, "it never reached the transport")

            // One may wait; the next is over the queue.
            let waiting = rig.start(.get("/a?waiting"))
            await eventually { waiters(rig) == 1 }
            let overflow = try #require(await rig.httpError(of: rig.start(.get("/a?overflow"))))
            #expect(overflow.rejection?.reason == .rateLimited)
            #expect(rig.transport.requestCount == 1)
            await rig.clock.advance(by: .seconds(10))
            #expect(try await waiting.value.status == 200)
            #expect(rig.clock.now.offset == .seconds(10))
        }
    }

    // Row: a caller waiting for a rate-limit permit is cancelled.
    @Test(.failureMode("design/19", "a caller waiting for a rate-limit permit is cancelled"))
    func aCancelledWaiterLeavesWithoutTakingAPermit() async throws {
        let limit = HTTPRateLimit(rate: 1, per: .seconds(1))
        try await withRig(.testing(rateLimit: limit)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [], then: .status(200))
            _ = try await rig.start(.get("/a")).value
            let leaving = rig.start(.get("/a?leaving"))
            await eventually { waiters(rig) == 1 }
            leaving.cancel()
            #expect(await rig.failure(of: leaving) is CancellationError)
            #expect(waiters(rig) == 0)
            #expect(rig.transport.requestCount == 1)

            // The permit it never took goes to the next caller.
            let next = rig.start(.get("/a?next"))
            await eventually { waiters(rig) == 1 }
            await rig.clock.advance(by: .seconds(1))
            #expect(try await next.value.status == 200)
            #expect(rig.clock.now.offset == .seconds(1))
        }
    }

    @Test func eachHostHasABucketOfItsOwn() async throws {
        let limit = HTTPRateLimit(rate: 1, per: .seconds(10))
        try await withRig(.testing(rateLimit: limit)) { (rig) async throws in
            let other = try #require(URL(string: "https://other.example.com/a"))
            rig.transport.on(.get("/a"), respond: [], then: .status(200))
            rig.transport.on(.get(other), respond: [], then: .status(200))
            _ = try await rig.start(.get("/a")).value
            _ = try await rig.start(.get(other)).value
            #expect(rig.transport.requestCount == 2)
            #expect(rig.clock.now.offset == .zero, "the other host's bucket was full")
            #expect(rig.api.rateLimiter(forHost: "other.example.com") !== rig.api.rateLimiter(forHost: "api.example.com"))
        }
    }

    @Test func aBreakerThatRefusesTheCallLeavesThePermitUntaken() async throws {
        let limit = HTTPRateLimit(rate: 1, per: .seconds(10))
        try await withRig(.testing(attempts: 1, rateLimit: limit)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [], then: .status(200))
            _ = try await rig.start(.get("/a")).value
            let breaker = try #require(rig.api.breaker(forHost: "api.example.com"))
            breaker.forceOpen()
            for _ in 0..<3 {
                let error = try #require(await rig.httpError(of: rig.start(.get("/a"))))
                #expect(error.rejection?.reason == .circuitOpen, "the breaker is checked first, and the limiter never sees the call")
            }
            #expect(waiters(rig) == 0)
        }
    }

    @Test func noRateLimitMeansNoLimiter() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [], then: .status(200))
            _ = try await rig.start(.get("/a")).value
            #expect(rig.api.rateLimiter(forHost: "api.example.com") == nil)
        }
    }
}
