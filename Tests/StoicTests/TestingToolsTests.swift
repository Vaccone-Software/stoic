import Stoic
import StoicTesting
import Testing

@Suite("Testing tools")
struct TestingToolsTests {
    enum APIError: Error, Equatable { case offline }

    @Test func aFaultScriptDrivesARetry() async throws {
        let api = FaultInjector<APIError>.failing(2, with: .offline)
        let value = try await withTestAmbient(clock: ImmediateClock()) {
            try await retry(.fixed(.seconds(1)).attempts(5)) { _ throws(APIError) -> Int in
                try await api.run { () throws(APIError) -> Int in 42 }
            }
        }
        #expect(value == 42)
        #expect(api.callCount == 3)
    }

    @Test func latencyUsesTheAmbientClock() async throws {
        let clock = ImmediateClock()
        let api = FaultInjector<APIError>([.latency(.seconds(7))])
        try await withTestAmbient(clock: clock) {
            try await api.run { () throws(APIError) in }
        }
        #expect(clock.sleeps == [.seconds(7)])
    }

    @Test func aHangIgnoringCancellationOutlivesItsTimeout() async throws {
        let clock = TestClock()
        let gate = TestGate()
        let api = FaultInjector<CancellationError>([.hangIgnoringCancellation(gate)])
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) { try await api.run { () throws(CancellationError) in "late" } }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        #expect(await eventually { clock.sleeperCount == 0 }, "the timeout fired and was not waited out")
        #expect(!gate.isOpen)
        gate.open()
        #expect(try await task.value == "late", "cooperative timeouts wait for uncooperative work")
    }

    @Test(.stoic(seed: 7))
    func theTraitInstallsASeedAndRecordsEvents() async throws {
        #expect(Ambient.current.random == .seeded(7))
        _ = try? await retry(.fixed(.zero).attempts(2), clock: ImmediateClock().erased) { _ throws(APIError) -> Int in throw .offline }
        #expect(StoicTest.events.names.contains("retry.exhausted"))
    }
}

@Suite("Golden traces")
struct GoldenTraceTests {
    enum Flaky: Error, Retryable {
        case unavailable
        var retryDecision: RetryDecision { .retry }
    }

    @Test func aRetryScenarioMakesExactlyTheDecisionsItShould() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let failures = SendableBox(0)
        let task = Task {
            try await withTestAmbient(clock: clock, seed: 1, events: events) {
                try await retry(.fixed(.milliseconds(200)).attempts(3), budget: .unlimited, label: "sync") { _ async throws(Flaky) -> Int in
                    if failures.mutate({ $0 += 1; return $0 }) < 2 { throw .unavailable }
                    return 1
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(200))
        _ = try await task.value
        expectTrace(events, """
            info retry.attempt_failed label=sync attempt=1 error=<private> delay=0.2 seconds timed_out=false decision=retry
            info retry.succeeded label=sync attempts=2 elapsed=0.2 seconds
            """)
    }

    @Test func aDifferentTraceIsAnIssueThatShowsTheActualOne() {
        let events = RecordingInstrumentation()
        events.record(Event("retry.succeeded", level: .info, label: "sync", fields: [.init("attempts", .int(2))]))
        withKnownIssue {
            expectTrace(events, "info retry.succeeded label=sync attempts=3")
        } matching: { issue in
            "\(issue)".contains("attempts=2")
        }
    }

    @Test func privateValuesAreRedactedInTraces() {
        let events = RecordingInstrumentation()
        events.record(Event("test.private", level: .warning, fields: [.init("user", .string("alice"))]))
        #expect(events.trace() == "warning test.private user=<private>")
    }
}
