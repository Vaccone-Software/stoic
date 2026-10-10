import Foundation
import Stoic
import StoicHTTP
import StoicJSON
import StoicTesting
import Testing

/// Failure-mode rows of design/19 about retrying: what is repeated, when,
/// and how long the client waits.
@Suite("HTTP retry")
struct HTTPRetryTests {
    // Row: a GET gets 503 twice, then 200.
    @Test(.failureMode("design/19", "a GET gets 503 twice, then 200")) func aGetRetriesTwiceWithBackoffThenReturnsTheSuccess() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/users/42"), respond: [.status(503), .status(503), .json(#"{"id": 42}"#)])
            let task = rig.start(.get("/users/42"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            await rig.waitForBackoff(2)
            await rig.clock.advance(by: .seconds(2))
            let response = try await task.value
            #expect(response.status == 200)
            #expect(response.text == #"{"id": 42}"#)
            #expect(rig.transport.requestCount == 3)
            #expect(rig.clock.now.offset == .seconds(3))

            let retries = rig.events.events(named: "http.retry")
            #expect(retries.count == 2)
            #expect(retries.map { $0.duration("delay") } == [.seconds(1), .seconds(2)])
            #expect(retries.map { $0.text("reason") } == ["status_503", "status_503"])
            #expect(retries.map { $0.number("attempt") } == [2, 3])
            #expect(rig.events.count("http.failed") == 0)
        }
    }

    @Test func theAttemptsAreBoundedByTheSchedule() async throws {
        try await withRig(.testing(attempts: 3)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503, body: "busy")])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            await rig.waitForBackoff(2)
            await rig.clock.advance(by: .seconds(2))
            let error = await rig.httpError(of: task)
            #expect(error == .status(503, excerpt: "busy", retryAfter: nil, attempts: 3))
            #expect(error?.wasRetried == true)
            #expect(rig.transport.requestCount == 3)
            #expect(rig.events.count("http.failed") == 1)
        }
    }

    @Test func aStatusOutsideTheRetrySetIsFinalEvenForAGet() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(501)])
            #expect(await rig.httpError(of: rig.start(.get("/a"))) == .status(501, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(rig.transport.requestCount == 1)
            #expect(rig.clock.sleeperCount == 0)
        }
    }

    // Row: a POST without an idempotency key times out.
    @Test(.failureMode("design/19", "a POST without an idempotency key times out")) func anUnkeyedPostThatTimesOutIsNotRetried() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.post("/orders", json: [:]), respond: [.hang])
            let task = rig.start(.post("/orders", json: [:]))
            await rig.waitForHangingAttempt()
            await rig.clock.advance(by: .seconds(10))
            #expect(await rig.httpError(of: task) == .timedOut(attempt: 1))
            #expect(rig.transport.requestCount == 1)
            #expect(rig.transport.abortedCount == 1)
            #expect(rig.events.count("retry.attempt_failed") == 0)
        }
    }

    @Test func anUnkeyedPostIsNotRetriedOnAnyFailure() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.post("/a", json: [:]), respond: [.status(503)])
            rig.transport.on(.patch("/b", json: [:]), respond: [.failure(.networkConnectionLost)])
            #expect(await rig.httpError(of: rig.start(.post("/a", json: [:]))) == .status(503, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(await rig.httpError(of: rig.start(.patch("/b", json: [:]))) == .transport(.networkConnectionLost, attempts: 1))
            #expect(rig.transport.requestCount == 2)
        }
    }

    // Row: a POST with a key gets 503.
    @Test(.failureMode("design/19", "a POST with a key gets 503")) func aKeyedPostIsRetriedWithTheSameKeyOnEveryAttempt() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.post("/orders", json: [:]), respond: [.status(503), .failure(.networkConnectionLost), .status(201)])
            let key = IdempotencyKey.random()
            let task = rig.start(.post("/orders", json: ["id": 1]), key: key)
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            await rig.waitForBackoff(2)
            await rig.clock.advance(by: .seconds(2))
            #expect(try await task.value.status == 201)
            #expect(rig.transport.requestCount == 3)
            let sent = rig.sentHeaders.map { $0["Idempotency-Key"] }
            #expect(sent == [key.rawValue, key.rawValue, key.rawValue])
            #expect(rig.transport.requests.allSatisfy { $0.body == Array(#"{"id":1}"#.utf8) })
        }
    }

    @Test func aPatchWithAKeyIsRetriedToo() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.patch("/a", json: [:]), respond: [.status(502), .status(200)])
            let task = rig.start(.patch("/a", json: [:]).keyed(IdempotencyKey(rawValue: "abc")))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
            #expect(rig.sentHeaders.map { $0["idempotency-key"] } == ["abc", "abc"])
        }
    }

    @Test func putAndDeleteAreIdempotentAndRetriedWithoutAKey() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.delete("/a"), respond: [.status(500), .status(204)])
            let task = rig.start(.delete("/a"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 204)
            #expect(rig.transport.requestCount == 2)
            #expect(rig.sentHeaders.allSatisfy { !$0.contains("Idempotency-Key") })
        }
    }

    // Row: the server says 429 with Retry-After: 30.
    @Test(.failureMode("design/19", "the server says 429 with Retry-After: 30")) func retryAfterInSecondsReplacesTheBackoff() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(429, headers: ["Retry-After": "30"]), .status(200)])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(30))], "30 s, not the schedule's 1 s")
            await rig.clock.advance(by: .seconds(29))
            #expect(rig.transport.requestCount == 1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
            #expect(rig.events.events(named: "http.retry").map { $0.duration("delay") } == [.seconds(30)])
        }
    }

    @Test func retryAfterAsAnHTTPDateIsRelativeToTheWallClock() async throws {
        let now = Date(timeIntervalSince1970: 784_111_777)   // Sun, 06 Nov 1994 08:49:37 GMT
        try await withRig(.testing(wallClock: { now })) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503, headers: ["Retry-After": "Sun, 06 Nov 1994 08:50:07 GMT"]), .status(200)])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(30))])
            await rig.clock.advance(by: .seconds(30))
            #expect(try await task.value.status == 200)
        }
    }

    @Test func retryAfterIsCappedByThePolicy() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(429, headers: ["Retry-After": "86400"]), .status(200)])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(60))], "HTTPPolicy.maxRetryAfter")
            await rig.clock.advance(by: .seconds(60))
            #expect(try await task.value.status == 200)
        }
    }

    @Test func aRetryAfterThatOutlastsTheDeadlineIsNotWaitedFor() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(429, headers: ["Retry-After": "30"]), .status(200)])
            let api = rig.api
            let task = Task { try await withTimeout(.seconds(5)) { try await api.send(.get("/a")) } }
            await eventually { rig.transport.requestCount == 1 && rig.events.count("http.failed") == 1 }
            let error = try #require(await rig.failure(of: task) as? HTTPError)
            let rejection = try #require(error.rejection)
            #expect(rejection.reason == .deadlineExceeded)
            #expect(rejection.retryAfter == .seconds(30), "the server's wait is in the rejection")
            #expect(error.attempts == 1)
            #expect(rig.clock.now.offset == .zero, "it failed at once")
            #expect(rig.transport.requestCount == 1)
        }
    }

    // Row: one attempt hangs.
    @Test(.failureMode("design/19", "one attempt hangs")) func aHangingAttemptIsCutAtTheTimeoutAndRetried() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.hang, .status(200)])
            let task = rig.start(.get("/a"))
            await rig.waitForHangingAttempt()
            await rig.clock.advance(by: .seconds(10))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
            #expect(rig.transport.abortedCount == 1)
            #expect(rig.events.events(named: "http.retry").map { $0.text("reason") } == ["timed_out"])
            #expect(rig.clock.now.offset == .seconds(11))
        }
    }

    // Row: the caller's deadline passes mid-backoff.
    @Test(.failureMode("design/19", "the caller's deadline passes mid-backoff")) func noAttemptIsStartedThatCouldNotFinishBeforeTheDeadline() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503)])
            let api = rig.api
            let task = Task { try await withTimeout(.seconds(3)) { try await api.send(.get("/a")) } }
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            await eventually { rig.events.count("http.failed") == 1 }
            let error = try #require(await rig.failure(of: task) as? HTTPError)
            #expect(error.rejection?.reason == .deadlineExceeded)
            #expect(error.attempts == 2)
            #expect(rig.transport.requestCount == 2, "the third attempt would have started at 3 s")
        }
    }

    @Test func aDeadlineThatPassesDuringAnAttemptIsARejectionNotATimeout() async throws {
        try await withRig(.testing(coalesce: false)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.hang])
            let api = rig.api
            let task = Task { try await withTimeout(.seconds(4)) { try await api.send(.get("/a")) } }
            await rig.waitForHangingAttempt(timers: 1)   // the caller's deadline
            await rig.clock.advance(by: .seconds(4))
            let error = try #require(await rig.failure(of: task) as? HTTPError)
            #expect(error == .rejected(Rejection(.deadlineExceeded, label: "http api.example.com"), attempts: 1))
            #expect(rig.transport.requestCount == 1)
            #expect(rig.transport.abortedCount == 1)
        }
    }

    @Test func aCoalescedGetHonoursTheDeadlineToo() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.hang])
            let api = rig.api
            let task = Task { try await withTimeout(.seconds(4)) { try await api.send(.get("/a")) } }
            // The caller's deadline, the flight's wait, the starter's deadline lent to the flight, the attempt and the hang.
            await rig.waitForHangingAttempt(timers: 3)
            await rig.clock.advance(by: .seconds(4))
            let error = try #require(await rig.failure(of: task) as? HTTPError)
            #expect(error.rejection?.reason == .deadlineExceeded)
            await eventually { rig.transport.abortedCount == 1 }
            #expect(rig.transport.requestCount == 1)
        }
    }

    @Test func aSpentRetryBudgetEndsTheRetriesAsARejection() async throws {
        let empty = RetryBudget(ratio: 0, reservePerSecond: 0, reserveCapacity: 0)
        try await withRig(.testing(retryBudget: empty)) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503)])
            let error = await rig.httpError(of: rig.start(.get("/a")))
            #expect(error == .rejected(Rejection(.budgetExhausted, label: "http api.example.com"), attempts: 1))
            #expect(rig.transport.requestCount == 1)
        }
    }

    @Test func aTransportErrorIsRetriedOnlyWhenRetryingCouldHelp() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/flaky"), respond: [.failure(.cannotConnectToHost), .status(200)])
            rig.transport.on(.get("/untrusted"), respond: [.failure(.serverCertificateUntrusted)])
            let flaky = rig.start(.get("/flaky"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await flaky.value.status == 200)
            #expect(await rig.httpError(of: rig.start(.get("/untrusted"))) == .transport(.serverCertificateUntrusted, attempts: 1))
            #expect(rig.transport.requests(to: .get("/untrusted")).count == 1)
        }
    }

    @Test func aRetryInsideAnotherRetrysAttemptMakesOneAttempt() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503), .status(200)])
            let api = rig.api
            let error = await #expect(throws: HTTPError.self) {
                try await retry(.immediate.attempts(1)) { _ in try await api.send(.get("/a")) }
            }
            #expect(error?.attempts == 1, "whoever retries around the client owns the retrying")
        }
    }
}
