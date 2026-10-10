@testable import Stoic
import StoicTesting
import Testing

@Suite("Supervisor")
struct SupervisorTests {
    struct Crash: Error {}

    /// Counts starts per child and lets a test decide how each run ends.
    final class Script: Sendable {
        let starts = SendableBox<[String: Int]>([:])
        func started(_ name: String) -> Int {
            starts.mutate { $0[name, default: 0] += 1; return $0[name]! }
        }
        func count(_ name: String) -> Int { starts.value[name] ?? 0 }
    }

    @Test func aPermanentChildIsRestartedAfterItsBackoff() async throws {
        let clock = TestClock()
        let script = Script()
        let supervisor = Supervisor(label: "test", backoff: .fixed(.seconds(2))) {
            Child("worker") { _ in
                if script.started("worker") < 3 { throw Crash() }
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }
        for expected in 2...3 {
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(2))
            for _ in 0..<500 where script.count("worker") < expected { await Task.yield() }
            #expect(script.count("worker") == expected)
        }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
    }

    @Test func transientAndTemporaryChildrenFinishAndTheSupervisorReturns() async throws {
        let script = Script()
        let supervisor = Supervisor(label: "test") {
            Child("transient", restart: .transient) { _ in _ = script.started("transient") }
            Child("temporary", restart: .temporary) { _ in
                _ = script.started("temporary")
                throw Crash()
            }
        }
        try await withTestAmbient(clock: TestClock()) { try await supervisor.run() }
        #expect(script.count("transient") == 1)
        #expect(script.count("temporary") == 1)
    }

    @Test func exceedingTheIntensityEscalates() async throws {
        let events = RecordingInstrumentation()
        let supervisor = Supervisor(label: "test", intensity: .init(maxRestarts: 2, within: .seconds(60)), backoff: .immediate) {
            Child("doomed") { _ in throw Crash() }
            Child("bystander") { _ in try await Task.sleep(for: .seconds(3600)) }
        }
        do {
            try await withTestAmbient(clock: TestClock(), events: events) { try await supervisor.run() }
            Issue.record("expected escalation")
        } catch let escalation as SupervisorEscalation {
            #expect(escalation.child == "doomed")
            #expect(escalation.lastError is Crash)
        }
        #expect(events.names.contains("supervisor.escalated"))
    }

    @Test func oneForAllRestartsEveryChild() async throws {
        let script = Script()
        let supervisor = Supervisor(label: "test", strategy: .oneForAll, backoff: .immediate) {
            Child("a") { _ in
                _ = script.started("a")
                try await Task.sleep(for: .seconds(3600))
            }
            Child("b", restart: .transient) { _ in
                if script.started("b") == 1 { throw Crash() }
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let run = Task { try await withTestAmbient(clock: TestClock()) { try await supervisor.run() } }
        for _ in 0..<2_000 where script.count("a") < 2 || script.count("b") < 2 { await Task.yield() }
        #expect(script.count("a") == 2)
        #expect(script.count("b") == 2)
        run.cancel()
        _ = try? await run.value
    }

    @Test func restForOneRestartsOnlyLaterChildren() async throws {
        let script = Script()
        let supervisor = Supervisor(label: "test", strategy: .restForOne, backoff: .immediate) {
            Child("first") { _ in
                _ = script.started("first")
                try await Task.sleep(for: .seconds(3600))
            }
            Child("middle") { _ in
                if script.started("middle") == 1 { throw Crash() }
                try await Task.sleep(for: .seconds(3600))
            }
            Child("last") { _ in
                _ = script.started("last")
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let run = Task { try await withTestAmbient(clock: TestClock()) { try await supervisor.run() } }
        for _ in 0..<2_000 where script.count("middle") < 2 || script.count("last") < 2 { await Task.yield() }
        #expect(script.count("first") == 1)
        #expect(script.count("middle") == 2)
        #expect(script.count("last") == 2)
        run.cancel()
        _ = try? await run.value
    }

    @Test func aChildThatStopsBeatingIsRestarted() async throws {
        let clock = TestClock()
        let script = Script()
        let events = RecordingInstrumentation()
        let supervisor = Supervisor(label: "test", backoff: .immediate) {
            Child("tap", heartbeat: .init(interval: .seconds(5), misses: 2, grace: .seconds(10))) { _ in
                _ = script.started("tap")
                try await Task.sleep(for: .seconds(3600))   // never beats
            }
        }
        let run = Task { try await withTestAmbient(clock: clock, events: events) { try await supervisor.run() } }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(10))   // grace
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(5))    // first miss
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(5))    // second miss: hung
        for _ in 0..<2_000 where script.count("tap") < 2 { await Task.yield() }
        #expect(script.count("tap") == 2)
        #expect(events.names.contains("supervisor.child_hung"))
        run.cancel()
        _ = try? await run.value
    }

    @Test func aBeatingChildIsLeftAlone() async throws {
        let clock = TestClock()
        let script = Script()
        let beat = SendableBox<Heartbeat?>(nil)
        let supervisor = Supervisor(label: "test", backoff: .immediate) {
            Child("tap", heartbeat: .init(interval: .seconds(5), misses: 1, grace: .zero)) { heartbeat in
                _ = script.started("tap")
                beat.mutate { $0 = heartbeat }
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }
        for _ in 0..<5 {
            await clock.waitForSleepers(count: 1)
            beat.value?.beat()
            await clock.advance(by: .seconds(5))
        }
        #expect(script.count("tap") == 1)
        run.cancel()
        _ = try? await run.value
    }

    @Test func cancellingTheSupervisorStopsChildrenWithACause() async throws {
        let causes = SendableBox<[String]>([])
        let started = AsyncGate()
        let supervisor = Supervisor(label: "test") {
            Child("one") { _ in
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    causes.mutate { $0.append("one:\(CancellationCause.current?.rawValue ?? "none")") }
                    throw error
                }
            }
            Child("two") { _ in
                started.open()
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    causes.mutate { $0.append("two:\(CancellationCause.current?.rawValue ?? "none")") }
                    throw error
                }
            }
        }
        let run = Task { try await supervisor.run() }
        await started.wait()
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(causes.value == ["two:supervisor_stopped", "one:supervisor_stopped"], "newest first")
    }

    @Test func aChildThatIgnoresCancellationIsAbandonedAfterItsTimeout() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let stuck = AsyncGate()
        let started = AsyncGate()
        let supervisor = Supervisor(label: "test") {
            Child("stubborn", shutdownTimeout: .seconds(3)) { _ in
                started.open()
                await stuck.wait()
            }
        }
        let run = Task { try await withTestAmbient(clock: clock, events: events) { try await supervisor.run() } }
        await started.wait()
        run.cancel()
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(3))
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(events.names.contains("supervisor.child_abandoned"))
        stuck.open()
    }
}
