import Foundation
import Stoic
@testable import StoicHTTP
import StoicJSON
import StoicTesting
import Testing

/// What an app whose retrying lives in an outbox needs of the policy: one
/// attempt, no breaker, and a say in what a keyed `409` means (design/19).
@Suite("HTTP policy shortcuts")
struct HTTPPolicyShortcutTests {
    /// A test policy (a predictable backoff, a free retry budget) that reads a
    /// keyed `409` as a refusal.
    static func refusingConflicts(attempts: Int = 3, retryOnResponse: (@Sendable (HTTPResponse) -> RetryDecision?)? = nil) -> HTTPPolicy {
        var policy = HTTPPolicy.testing(attempts: attempts, retryOnResponse: retryOnResponse)
        policy.keyedConflictIsInProgress = false
        return policy
    }

    // MARK: A keyed 409

    @Test func theDefaultReadsAKeyedConflictAsInProgress() {
        #expect(HTTPPolicy.standard.keyedConflictIsInProgress)
        #expect(HTTPPolicy.singleAttempt.keyedConflictIsInProgress)
    }

    @Test(.failureMode("design/19", "a keyed request is answered 409 and the policy reads it as a refusal"))
    func aKeyedConflictTheServerMeansAsARefusalIsFinalAndSaysSoToWhoeverRetriesAround() async throws {
        try await withRig(Self.refusingConflicts()) { (rig) async throws in
            rig.transport.on(.post("/mail", json: [:]), respond: [.status(409, body: "invalid_idempotent_request"), .status(201)])
            let error = try #require(await rig.httpError(of: rig.start(.post("/mail", json: [:]), key: .random())))
            #expect(error == .status(409, excerpt: "invalid_idempotent_request", retryAfter: nil, keyed: false, attempts: 1))
            #expect(rig.transport.requestCount == 1, "no wait, no second request")
            #expect(rig.clock.now.offset == .zero)
            // What an outbox's classifier reads: not a wait.
            #expect(error.retryDecision == .stop)
        }
    }

    @Test func aTooEarlyAnswerIsStillInProgressWhateverTheConflictSetting() async throws {
        try await withRig(Self.refusingConflicts()) { (rig) async throws in
            rig.transport.on(.post("/mail", json: [:]), respond: [.status(425), .status(201)])
            let task = rig.start(.post("/mail", json: [:]), key: .random())
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .seconds(1))
            #expect(try await task.value.status == 201)
            #expect(rig.transport.requestCount == 2)
        }
    }

    @Test func aCallersOwnVerdictStillRetriesAConflictAfterTheSchedulesDelay() async throws {
        let policy = Self.refusingConflicts(retryOnResponse: { $0.status == 409 ? .retry : nil })
        try await withRig(policy) { (rig) async throws in
            rig.transport.on(.post("/mail", json: [:]), respond: [.status(409), .status(201)])
            let quick = HTTPOverrides(schedule: Schedule.exponential(base: .milliseconds(100)).unjittered().attempts(3))
            let task = rig.start(.post("/mail", json: [:]), key: .random(), overrides: quick)
            await rig.waitForBackoff(1)
            await rig.clock.advance(by: .milliseconds(100))
            #expect(try await task.value.status == 201)
            #expect(rig.events.events(named: "http.retry").map { $0.duration("delay") } == [.milliseconds(100)], "the verdict's retry, not a wait of a second")
        }
    }

    @Test(.failureMode("design/19", "a keyed request is answered 409 and the policy reads it as a refusal"))
    func performTakesAConflictTheSettingMakesARefusalAsFinal() async throws {
        try await withRig(Self.refusingConflicts()) { (rig) async throws in
            rig.transport.on(.post("/mail", json: [:]), respond: [.status(409), .status(201)])
            let send = Backend.remote("http.refused-conflict").keyed("send")
            let task = HTTPOperationTests.perform(send, .post("/mail", json: [:]), via: rig, keyed: true)
            let error = try #require(await HTTPOperationTests.operationError(of: task, in: rig))
            #expect(error.attempts == 1, "the operation reads `.stop` from the error and does not ask again")
            #expect(rig.transport.requestCount == 1)
        }
    }

    // MARK: singleAttempt

    @Test func singleAttemptIsOneAttemptNoBreakerAndTheStandardTimeout() {
        let policy = HTTPPolicy.singleAttempt
        #expect(policy.schedule.maximumAttempts == 1)
        #expect(policy.breaker == nil)
        #expect(policy.attemptTimeout == HTTPPolicy.standard.attemptTimeout)
        #expect(policy.attemptTimeout == .seconds(10))
        // The rest is the standard policy's.
        #expect(policy.maxConcurrentPerHost == HTTPPolicy.standard.maxConcurrentPerHost)
        #expect(policy.maxRedirects == HTTPPolicy.standard.maxRedirects)
    }

    @Test(.failureMode("design/19", "a call is made under singleAttempt"))
    func aCallUnderSingleAttemptFailsAtOnceWithAnErrorThatClassifiesItself() async throws {
        try await withRig(.singleAttempt) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(503, headers: ["Retry-After": "7"]), .status(200)])
            let error = try #require(await rig.httpError(of: rig.start(.get("/a"))))
            #expect(error == .status(503, excerpt: "", retryAfter: .seconds(7), attempts: 1))
            #expect(rig.transport.requestCount == 1, "a GET that would be retried by the standard policy is not")
            #expect(rig.clock.now.offset == .zero, "no backoff")
            #expect(error.retryDecision == .retryAfter(.seconds(7)), "for the outbox to schedule")
        }
    }

    @Test(.failureMode("design/19", "a call is made under singleAttempt"))
    func theAttemptTimeoutIsKeptUnderSingleAttempt() async throws {
        try await withRig(.singleAttempt) { (rig) async throws in
            rig.transport.on(.post("/a", json: [:]), respond: [.hang])
            let task = rig.start(.post("/a", json: [:]), key: .random())
            await rig.waitForHangingAttempt()
            await rig.clock.advance(by: .seconds(10))
            #expect(await rig.httpError(of: task) == .timedOut(attempt: 1))
            #expect(rig.clock.now.offset == .seconds(10))
        }
    }

    @Test(.failureMode("design/19", "a call is made under singleAttempt"))
    func singleAttemptHasNoBreakerToOpenOnItsFailures() async throws {
        try await withRig(.singleAttempt) { (rig) async throws in
            rig.transport.on(.get("/a"), respond: [.status(500)])
            // Far more than the standard breaker's minimum of 20 calls, all failing.
            for _ in 0..<30 { _ = await rig.httpError(of: rig.start(.get("/a"))) }
            #expect(rig.api.breaker(forHost: "api.example.com") == nil)
            let error = try #require(await rig.httpError(of: rig.start(.get("/a"))))
            #expect(error.rejection == nil, "sent, and answered: not turned away")
            #expect(rig.transport.requestCount == 31)
        }
    }
}
