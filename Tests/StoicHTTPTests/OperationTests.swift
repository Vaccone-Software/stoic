import Foundation
import Stoic
@testable import StoicHTTP
import StoicJSON
import StoicTesting
import Testing

/// The client inside a declared operation's attempt (design/22, Inside
/// StoicHTTP): one attempt, the operation retrying, the client classifying;
/// and a keyed request's "in progress" answers.
@Suite("HTTP inside operations")
struct HTTPOperationTests {
    /// A `perform` of `operation` whose attempt sends `request` through the
    /// rig's client, with the attempt's own key when `keyed`.
    static func perform(_ operation: Backend.Operation, _ request: HTTPRequest, via rig: Rig, keyed: Bool = false, overrides: HTTPOverrides = .none) -> Sending {
        let api = rig.api
        return Task {
            try await operation.perform { attempt throws(any Error) in
                try await api.send(request, idempotencyKey: keyed ? attempt.idempotencyKey : nil, overrides: overrides)
            }
        }
    }

    static func operationError(of task: Sending, in rig: Rig) async -> OperationError<any Error>? {
        await rig.failure(of: task) as? OperationError<any Error>
    }

    /// Lets the operation's backoffs run their course. Its delays are a
    /// fraction of a second, so one advance carries the clock through every
    /// retry that follows: each timer is due before the advance ends.
    static func waitOutBackoffs(in rig: Rig) async {
        await rig.waitForBackoff(1)
        await rig.clock.advance(by: .seconds(5))
    }

    // MARK: Deferring

    // Rows: an HTTPClient call runs inside a perform attempt (design/22, design/19).
    @Test(
        .failureMode("design/22", "an HTTPClient call runs inside a perform attempt"),
        .failureMode("design/19", "a call runs inside a perform attempt")
    )
    func aCallInsideAPerformAttemptIsOneAttemptThroughNoBreakerBulkheadOrRateLimit() async throws {
        let policy = HTTPPolicy.testing(rateLimit: HTTPRateLimit(rate: 1, per: .seconds(3600)))
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503)])
            let fetch = Backend.remote("http.defers").readOnly("fetch")
            let task = Self.perform(fetch, .get("/a"), via: rig)
            await Self.waitOutBackoffs(in: rig)
            let error = try #require(await Self.operationError(of: task, in: rig))
            #expect(error.attempts == 3, "the operation's schedule: three attempts at userInitiated")
            #expect(rig.transport.requestCount == 3, "one request for each: the client retried none of them")
            #expect(error.last as? HTTPError == .status(503, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(rig.events.count("http.retry") == 0)
            #expect(rig.events.events(named: "retry.attempt_failed").map(\.label) == ["http.defers.fetch", "http.defers.fetch"])
            #expect(rig.api.hostCount == 0, "no host state: no breaker, bulkhead or rate limiter was consulted")
            #expect(rig.api.breaker(forHost: "api.example.com") == nil)
            #expect(rig.api.bulkhead(forHost: "api.example.com") == nil)
            #expect(rig.api.rateLimiter(forHost: "api.example.com") == nil)
        }
    }

    @Test func aCallOutsideAPerformAttemptStillRetriesAndGuardsItself() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503), .status(200)])
            let task = rig.start(.get("/a"))
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 200)
            #expect(rig.events.count("http.retry") == 1)
            #expect(rig.api.breaker(forHost: "api.example.com") != nil)
        }
    }

    @Test func redirectsAreStillFollowedInsideTheAttempt() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/old"), respond: [.status(302, headers: ["Location": "https://api.example.com/new"])])
            rig.transport.on(.get("/new"), respond: [.status(200, body: "arrived")])
            let fetch = Backend.remote("http.defers.redirect").readOnly("fetch")
            let response = try await Self.perform(fetch, .get("/old"), via: rig).value
            #expect(response.text == "arrived")
            #expect(rig.transport.requestCount == 2, "both hops, in the one attempt")
        }
    }

    @Test func callsInsideAttemptsAreNotCoalesced() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [], then: .status(200).after(.seconds(1)))
            let fetch = Backend.remote("http.defers.coalesce").readOnly("fetch")
            let first = Self.perform(fetch, .get("/a"), via: rig)
            let second = Self.perform(fetch, .get("/a"), via: rig)
            await eventually { rig.transport.inFlightCount == 2 }
            await rig.clock.advance(by: .seconds(1))
            #expect(try await first.value.status == 200)
            #expect(try await second.value.status == 200)
            #expect(rig.transport.requestCount == 2, "a flight would run outside the attempt the operation waits on")
        }
    }

    @Test func theOperationsTimerBoundsTheAttemptNotTheClientsOwnTimeout() async throws {
        try await withRig(.testing(timeout: .seconds(1))) { (rig) async throws in
            rig.transport.on(.get("/slow"), respond: [.hang])
            let fetch = Backend.remote("http.defers.timeout").readOnly("fetch")
            let task = Self.perform(fetch, .get("/slow"), via: rig)
            await rig.waitForHangingAttempt()
            await rig.clock.advance(by: .seconds(5))
            #expect(rig.transport.abortedCount == 0, "past the client's 1 s, short of the operation's 10 s")
            #expect(rig.transport.inFlightCount == 1)
            task.cancel()
            let error = await rig.failure(of: task)
            guard case .cancelled? = (error as? OperationError<any Error>)?.stop else {
                Issue.record("expected the cancellation the test caused, got \(String(describing: error))")
                return
            }
        }
    }

    @Test func aTimeoutTheCallAskedForStillCutsTheAttempt() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/slow"), respond: [.hang])
            let fetch = Backend.remote("http.defers.own-timeout").readOnly("fetch")
            let task = Self.perform(fetch, .get("/slow"), via: rig, overrides: HTTPOverrides(attemptTimeout: .seconds(2)))
            await rig.waitForHangingAttempt(timers: 1)
            await rig.clock.advance(by: .seconds(2))
            await eventually { rig.transport.abortedCount == 1 }
            task.cancel()
            _ = await rig.failure(of: task)
        }
    }

    // MARK: Classification for perform

    // Row: a call inside a perform attempt fails before a connection exists.
    @Test(.failureMode("design/19", "a call inside a perform attempt fails before a connection exists"))
    func aNonRepeatableOperationIsRepeatedWhenTheClientProvesNothingWasSent() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.post("/orders", json: [:]), respond: [.failure(.cannotFindHost)])
            let charge = Backend.remote("http.defers.unsent").notRepeatable("charge")
            let task = Self.perform(charge, .post("/orders", json: [:]), via: rig)
            await Self.waitOutBackoffs(in: rig)
            let error = try #require(await Self.operationError(of: task, in: rig))
            #expect(error.attempts == 3)
            #expect(error.outcome == .notExecuted)
            #expect(rig.transport.requestCount == 3)
            #expect(error.last as? HTTPError == .transport(.cannotFindHost, attempts: 1))
        }
    }

    // Row: a call inside a perform attempt fails after its request may have been sent.
    @Test(.failureMode("design/19", "a call inside a perform attempt fails after its request may have been sent"))
    func aNonRepeatableOperationIsNotRepeatedWhenTheRequestMayHaveBeenSent() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.post("/lost", json: [:]), respond: [.failure(.networkConnectionLost)])
            rig.transport.on(.post("/busy", json: [:]), respond: [.status(503)])
            let charge = Backend.remote("http.defers.sent").notRepeatable("charge")
            for path in ["/lost", "/busy"] {
                let before = rig.transport.requestCount
                let error = try #require(await Self.operationError(of: Self.perform(charge, .post(path, json: [:]), via: rig), in: rig))
                #expect(error.attempts == 1, "\(path)")
                #expect(error.outcome == .unknown, "\(path): the server may have acted")
                #expect(rig.transport.requestCount == before + 1, "\(path)")
            }
        }
    }

    @Test func aRedirectedRequestThatFailsLaterMayHaveBeenActedOn() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.post("/orders", json: [:]), respond: [.status(303, headers: ["Location": "https://elsewhere.example.com/receipt"])])
            rig.transport.on(.get(URL(string: "https://elsewhere.example.com/receipt")!), respond: [.failure(.cannotFindHost)])
            let charge = Backend.remote("http.defers.redirected").notRepeatable("charge")
            let error = try #require(await Self.operationError(of: Self.perform(charge, .post("/orders", json: [:]), via: rig), in: rig))
            #expect(error.attempts == 1, "the POST reached the server and was answered: it is not sent again")
            #expect(error.outcome == .unknown)
            #expect(error.last as? HTTPError == .transport(.cannotFindHost, attempts: 2))
            #expect(rig.transport.requestCount == 2)
        }
    }

    @Test func anErrorClaimsNeverReachedOnlyWhereItProvesIt() {
        // The codes StoicFoundation claims for URLError, and some it does not.
        let unsent: [URLError.Code] = [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet]
        let maybeSent: [URLError.Code] = [.timedOut, .networkConnectionLost, .badServerResponse, .secureConnectionFailed, .cancelled]
        for code in unsent {
            #expect(HTTPError.transport(code, attempts: 1).neverReachedBackend, "\(code)")
        }
        for code in maybeSent {
            #expect(!HTTPError.transport(code, attempts: 1).neverReachedBackend, "\(code)")
        }
        for code in unsent + maybeSent {
            #expect(!HTTPError.transport(code, attempts: 2).neverReachedBackend, "\(code): an earlier request may have reached the server")
        }
        #expect(HTTPError.rejected(Rejection(.circuitOpen, label: "x"), attempts: 0).neverReachedBackend, "turned away before it was sent")
        #expect(!HTTPError.rejected(Rejection(.budgetExhausted, label: "x"), attempts: 1).neverReachedBackend)
        #expect(!HTTPError.status(404, excerpt: "", retryAfter: nil, attempts: 1).neverReachedBackend)
        #expect(!HTTPError.timedOut(attempt: 1).neverReachedBackend)
        #expect(!HTTPError.responseTooLarge(limit: 1, attempts: 1).neverReachedBackend)
        #expect(!HTTPError.redirectRefused(.limit, status: 302, location: "/", attempts: 1).neverReachedBackend)
        #expect(!HTTPError.reauthenticationFailed(status: 401, attempts: 1).neverReachedBackend)
    }

    // MARK: In progress

    @Test func aKeyedRequestAnsweredInProgressIsTransientForItsClassification() {
        func decision(_ code: Int, keyed: Bool, retryAfter: Duration? = nil) -> RetryDecision {
            HTTPError.status(code, excerpt: "", retryAfter: retryAfter, keyed: keyed, attempts: 1).retryDecision
        }
        for code in [409, 425] {
            #expect(decision(code, keyed: true) == .retryAfter(.seconds(1)), "\(code): at least a second")
            #expect(decision(code, keyed: true, retryAfter: .seconds(5)) == .retryAfter(.seconds(5)), "\(code): the server may ask for more")
            #expect(decision(code, keyed: true, retryAfter: .zero) == .retryAfter(.seconds(1)), "\(code): never for less")
            #expect(decision(code, keyed: false) == .stop, "\(code): without a key it is the server's answer")
        }
        #expect(decision(503, keyed: true) == .retry)
        #expect(decision(404, keyed: true) == .stop)
        #expect(decision(422, keyed: true) == .stop)
    }

    // Rows: a keyed request's retry is answered 409 or 425 (design/22), and a keyed request is (design/19).
    @Test(
        .failureMode("design/22", "a keyed request's retry is answered 409 or 425"),
        .failureMode("design/19", "a keyed request is answered 409 or 425")
    )
    func aKeyedRequestAnsweredInProgressIsRetriedAfterAtLeastASecond() async throws {
        for status in [409, 425] {
            try await withRig { (rig) async throws in
                rig.transport.on(.post("/orders", json: [:]), respond: [.status(status), .status(status), .status(201)])
                let key = IdempotencyKey.random()
                // A schedule that would retry far sooner than a second.
                let quick = HTTPOverrides(schedule: Schedule.exponential(base: .milliseconds(100)).unjittered().attempts(3))
                let task = rig.start(.post("/orders", json: [:]), key: key, overrides: quick)
                await rig.waitForBackoff(1)
                await rig.clock.advance(by: .milliseconds(999))
                #expect(rig.transport.requestCount == 1, "\(status): not before a second")
                await rig.clock.advance(by: .milliseconds(1))
                await rig.waitForBackoff(2)
                await rig.clock.advance(by: .seconds(1))
                #expect(try await task.value.status == 201)
                #expect(rig.transport.requestCount == 3)
                #expect(rig.events.events(named: "http.retry").map { $0.duration("delay") } == [.seconds(1), .seconds(1)])
                #expect(rig.events.events(named: "http.retry").map { $0.text("reason") } == ["status_\(status)", "status_\(status)"])
                #expect(rig.sentHeaders.map { $0["Idempotency-Key"] } == Array(repeating: key.rawValue, count: 3))
            }
        }
    }

    @Test func aRetryAfterLongerThanASecondIsHonouredAndAShorterOneRaisedToIt() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.post("/a", json: [:]), respond: [.status(409, headers: ["Retry-After": "5"]), .status(409, headers: ["Retry-After": "0"]), .status(201)])
            let quick = HTTPOverrides(schedule: Schedule.exponential(base: .milliseconds(100)).unjittered().attempts(3))
            let task = rig.start(.post("/a", json: [:]), key: IdempotencyKey.random(), overrides: quick)
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(5))
            await rig.waitForBackoff(2)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 201)
            #expect(rig.events.events(named: "http.retry").map { $0.duration("delay") } == [.seconds(5), .seconds(1)])
        }
    }

    @Test func anInProgressAnswerWithoutAKeyIsFinalAndAKeyedOneThatNeverClearsFailsKeyed() async throws {
        try await withRig(.testing(attempts: 2)) { (rig) async throws in
            rig.transport.on(.post("/unkeyed", json: [:]), respond: [.status(409)])
            rig.transport.on(.get("/read"), respond: [.status(425)])
            rig.transport.on(.post("/keyed", json: [:]), respond: [.status(409)])
            #expect(await rig.httpError(of: rig.start(.post("/unkeyed", json: [:]))) == .status(409, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(await rig.httpError(of: rig.start(.get("/read"))) == .status(425, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(rig.transport.requestCount == 2, "a conflict is the server's answer, not a wait")

            let task = rig.start(.post("/keyed", json: [:]), key: IdempotencyKey.random())
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(await rig.httpError(of: task) == .status(409, excerpt: "", retryAfter: nil, keyed: true, attempts: 2))
        }
    }

    // Row: a keyed request's retry is answered 409 or 425, as perform sees it.
    @Test(.failureMode("design/22", "a keyed request's retry is answered 409 or 425"))
    func performSeesAKeyedInProgressAnswerAsTransientAndRetriesAfterASecond() async throws {
        for status in [409, 425] {
            try await withRig { (rig) async throws in
                rig.transport.on(.post("/orders", json: [:]), respond: [.status(status), .status(201)])
                let charge = Backend.remote("http.in-progress").keyed("charge")
                let task = Self.perform(charge, .post("/orders", json: [:]), via: rig, keyed: true)
                await rig.waitForBackoff(1)
                await rig.clock.advance(by: .milliseconds(999))
                #expect(rig.transport.requestCount == 1, "\(status): the operation's own first delay is a tenth of that")
                await rig.clock.advance(by: .milliseconds(1))
                #expect(try await task.value.status == 201)
                let sent = rig.sentHeaders.map { $0["Idempotency-Key"] }
                #expect(sent.count == 2 && sent[0] != nil && sent[0] == sent[1], "the operation's key, on every attempt")
            }
        }
    }

    @Test func performTakesAnUnkeyedConflictAsTheAnswer() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.put("/a", json: [:]), respond: [.status(409)])
            let replace = Backend.remote("http.conflict").idempotent("replace")
            let error = try #require(await Self.operationError(of: Self.perform(replace, .put("/a", json: [:]), via: rig), in: rig))
            #expect(error.attempts == 1)
            #expect(error.outcome == .executed)
            #expect(rig.transport.requestCount == 1)
        }
    }
}
