import Foundation
import Stoic
@testable import StoicHTTP
import StoicTesting
import Testing

/// What one call changes about the policy, for that call only.
@Suite("HTTP overrides")
struct HTTPOverrideTests {
    // Row: a call asks for its own attempt timeout and retry schedule.
    @Test(.failureMode("design/19", "a call asks for its own attempt timeout and retry schedule"))
    func aCallCanHaveItsOwnTimeoutAndScheduleWhileTheNextUsesThePolicys() async throws {
        try await withRig(.testing(attempts: 3, timeout: .seconds(10))) { (rig) async throws in
            rig.transport.on(.get("/report"), respond: [.hang, .status(200)])
            let overrides = HTTPOverrides(attemptTimeout: .seconds(30), schedule: Schedule.fixed(.seconds(5)).attempts(2))
            let task = rig.start(.get("/report"), overrides: overrides)
            await rig.waitForHangingAttempt()
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(30))], "30 s, not the policy's 10 s")
            await rig.clock.advance(by: .seconds(29))
            #expect(rig.transport.abortedCount == 0)
            await rig.clock.advance(by: .seconds(1))
            await rig.waitForBackoff(1)
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(35))], "5 s, not the policy's 1 s")
            await rig.clock.advance(by: .seconds(5))
            #expect(try await task.value.status == 200)
            #expect(rig.events.events(named: "http.retry").map { $0.duration("delay") } == [.seconds(5)])

            // The next call has the policy's.
            rig.transport.on(.get("/other"), respond: [.hang])
            let plain = rig.start(.get("/other"))
            await rig.waitForHangingAttempt()
            #expect(rig.clock.pendingDeadlines == [.init(offset: .seconds(45))])
            await rig.clock.advance(by: .seconds(10))
            await rig.waitForBackoff(2)
            plain.cancel()
            _ = await rig.failure(of: plain)
        }
    }

    @Test func aScheduleOfOneAttemptTurnsRetryingOffForTheCall() async throws {
        try await withRig(.testing(attempts: 3)) { (rig) async throws in
            rig.transport.on(.get("/health"), respond: [.status(503)])
            let error = await rig.httpError(of: rig.start(.get("/health"), overrides: HTTPOverrides(schedule: Schedule.immediate.attempts(1))))
            #expect(error == .status(503, excerpt: "", retryAfter: nil, attempts: 1))
            #expect(rig.transport.requestCount == 1)
            #expect(rig.clock.sleeperCount == 0)
        }
    }

    // Row: a call opts out of the breaker while it is open.
    @Test(.failureMode("design/19", "a call opts out of the breaker while it is open"))
    func aCallThatBypassesTheBreakerIsSentWhileItIsOpen() async throws {
        try await withRig(.testing(attempts: 1)) { (rig) async throws in
            rig.transport.on(.get("/ping"), respond: [], then: .status(200))
            _ = try await rig.start(.get("/ping")).value
            let breaker = try #require(rig.api.breaker(forHost: "api.example.com"))
            breaker.forceOpen()

            let refused = try #require(await rig.httpError(of: rig.start(.get("/ping"))))
            #expect(refused.rejection?.reason == .circuitOpen)
            #expect(rig.transport.requestCount == 1)

            let response = try await rig.start(.get("/ping"), overrides: HTTPOverrides(bypassBreaker: true)).value
            #expect(response.status == 200)
            #expect(rig.transport.requestCount == 2)
            #expect(breaker.state == .open, "what the bypassing call saw does not close it")
        }
    }

    @Test func aBypassingCallsFailuresAreNotCountedAgainstTheHost() async throws {
        try await withRig(.testing(attempts: 1)) { (rig) async throws in
            rig.transport.on(.get("/ping"), respond: [], then: .status(200))
            rig.transport.on(.get("/broken"), respond: [.status(500)])
            _ = try await rig.start(.get("/ping")).value
            let breaker = try #require(rig.api.breaker(forHost: "api.example.com"))
            let before = breaker.snapshot.failures
            for _ in 0..<5 { _ = await rig.httpError(of: rig.start(.get("/broken"), overrides: HTTPOverrides(bypassBreaker: true))) }
            #expect(breaker.snapshot.failures == before)
        }
    }

    @Test func aCallCanTurnCoalescingOffForItself() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/avatar"), respond: [Step.bytes([1]).after(.seconds(1))])
            let shared = rig.start(.get("/avatar"))
            let alone = rig.start(.get("/avatar"), overrides: HTTPOverrides(coalesce: false))
            await eventually { rig.transport.inFlightCount == 2 }
            await rig.clock.waitForSleepers(count: 4)
            await rig.clock.advance(by: .seconds(1))
            _ = try await shared.value
            _ = try await alone.value
            #expect(rig.transport.requestCount == 2)
        }
    }

    @Test func aCallCanTurnCoalescingOnWhenThePolicyHasItOff() async throws {
        try await withRig(.testing(coalesce: false)) { (rig) async throws in
            rig.transport.on(.get("/avatar"), respond: [Step.bytes([1]).after(.seconds(1))])
            let overrides = HTTPOverrides(coalesce: true)
            let tasks = (0..<3).map { _ in rig.start(.get("/avatar"), overrides: overrides) }
            await eventually("every caller joins the flight") { rig.api.coalescedWaiters(for: .get("/avatar"), overrides: overrides) == 3 }
            await rig.clock.waitForSleepers(count: 2)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { _ = try await task.value }
            #expect(rig.transport.requestCount == 1)
            // Without the override the same calls are not shared.
            let plain = [rig.start(.get("/avatar")), rig.start(.get("/avatar"))]
            await eventually { rig.transport.inFlightCount == 2 }
            await rig.clock.waitForSleepers(count: 4)
            await rig.clock.advance(by: .seconds(1))
            for task in plain { _ = try await task.value }
            #expect(rig.transport.requestCount == 3)
        }
    }

    @Test func callsWithDifferentSchedulesDoNotShareAFlight() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/avatar"), respond: [Step.bytes([1]).after(.seconds(1))])
            let twice = HTTPOverrides(schedule: Schedule.fixed(.seconds(5)).attempts(2))
            let once = HTTPOverrides(schedule: Schedule.fixed(.seconds(5)).attempts(1))
            let tasks = [rig.start(.get("/avatar"), overrides: twice), rig.start(.get("/avatar"), overrides: once),
                         rig.start(.get("/avatar"), overrides: twice)]
            await eventually("the two alike join one flight") { rig.api.coalescedWaiters(for: .get("/avatar"), overrides: twice) == 2 }
            await eventually { rig.transport.inFlightCount == 2 }
            await rig.clock.waitForSleepers(count: 4)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { _ = try await task.value }
            #expect(rig.transport.requestCount == 2, "the two alike share, the third does not")
        }
    }

    @Test func aFlightIsKeyedByTheOverridesValuesNotTheirHashes() {
        let request = HTTPRequest(method: .get, target: .url(apiBase))
        let schedule = Schedule.exponential(base: .seconds(1)).attempts(3)
        let key = FlightKey(request, ignoring: [], overrides: HTTPOverrides(schedule: schedule))
        #expect(key.schedule == schedule)
        #expect(key == FlightKey(request, ignoring: [], overrides: HTTPOverrides(schedule: Schedule.exponential(base: .seconds(1)).attempts(3))))
        #expect(key != FlightKey(request, ignoring: [], overrides: HTTPOverrides(schedule: schedule.capped(at: .seconds(2)))))
        #expect(key != FlightKey(request, ignoring: [], overrides: .none))
    }

    @Test func callsWithDifferentTimeoutsDoNotShareAFlight() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/avatar"), respond: [Step.bytes([1]).after(.seconds(1))])
            let short = rig.start(.get("/avatar"), overrides: HTTPOverrides(attemptTimeout: .seconds(5)))
            let long = rig.start(.get("/avatar"), overrides: HTTPOverrides(attemptTimeout: .seconds(50)))
            let same = rig.start(.get("/avatar"), overrides: HTTPOverrides(attemptTimeout: .seconds(5)))
            await eventually("the two alike join one flight") {
                rig.api.coalescedWaiters(for: .get("/avatar"), overrides: HTTPOverrides(attemptTimeout: .seconds(5))) == 2
            }
            await eventually { rig.transport.inFlightCount == 2 }
            await rig.clock.waitForSleepers(count: 4)
            await rig.clock.advance(by: .seconds(1))
            for task in [short, long, same] { _ = try await task.value }
            #expect(rig.transport.requestCount == 2, "the two alike share, the third does not")
        }
    }

    @Test func aCallWithItsOwnResponsePredicateIsNeverShared() async throws {
        try await withRig { (rig) async throws in
            rig.transport.on(.get("/avatar"), respond: [Step.bytes([1]).after(.seconds(1))])
            let overrides = HTTPOverrides(retryOnResponse: { _ in nil })
            let tasks = [rig.start(.get("/avatar"), overrides: overrides), rig.start(.get("/avatar"), overrides: overrides)]
            await eventually { rig.transport.inFlightCount == 2 }
            await rig.clock.waitForSleepers(count: 4)
            await rig.clock.advance(by: .seconds(1))
            for task in tasks { _ = try await task.value }
            #expect(rig.transport.requestCount == 2)
        }
    }

    @Test func overridesApplyToTheDecodingOverloadToo() async throws {
        try await withRig(.testing(attempts: 3)) { (rig) async throws in
            rig.transport.on(.get("/users/1"), respond: [.status(503)])
            let api = rig.api
            let error = await #expect(throws: HTTPError.self) {
                try await api.send(.get("/users/1"), overrides: HTTPOverrides(schedule: Schedule.immediate.attempts(1)), decoding: User.schema)
            }
            #expect(error?.attempts == 1)
        }
    }
}
