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

    @Test(.failureMode("design/09", "a permanent child throws")) func aPermanentChildIsRestartedAfterItsBackoff() async throws {
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
            await eventually { script.count("worker") >= expected }
            #expect(script.count("worker") == expected)
        }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
    }

    @Test(.failureMode("design/09", "a temporary child throws"), .failureMode("design/09", "a transient child returns")) func transientAndTemporaryChildrenFinishAndTheSupervisorReturns() async throws {
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

    @Test(.failureMode("design/09", "restarts exceed the intensity")) func exceedingTheIntensityEscalates() async throws {
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

    /// A schedule bounded by time ends once that much has passed since the
    /// failures began: restarting is not helping, so the supervisor escalates.
    @Test(.failureMode("design/09", "the backoff schedule ends")) func aBackoffBoundedByElapsedTimeEndsAndEscalates() async throws {
        let clock = TestClock()
        let script = Script()
        let supervisor = Supervisor(
            label: "test",
            intensity: .init(maxRestarts: 1000, within: .seconds(1)),
            backoff: Schedule.fixed(.seconds(1)).upTo(elapsed: .seconds(3))
        ) {
            Child("worker") { _ in
                _ = script.started("worker")
                throw Crash()
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }
        // Failures at 0, 1 and 2 s restart after a second; the one at 3 s,
        // three seconds into the streak, finds the schedule over.
        for _ in 0..<3 {
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(1))
        }
        await #expect(throws: SupervisorEscalation.self) { try await run.value }
        #expect(script.count("worker") == 4)
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
        await eventually { script.count("a") >= 2 && script.count("b") >= 2 }
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
        await eventually { script.count("middle") >= 2 && script.count("last") >= 2 }
        #expect(script.count("first") == 1)
        #expect(script.count("middle") == 2)
        #expect(script.count("last") == 2)
        run.cancel()
        _ = try? await run.value
    }

    @Test(.failureMode("design/09", "a child stops beating")) func aChildThatStopsBeatingIsRestarted() async throws {
        let clock = TestClock()
        let script = Script()
        let events = RecordingInstrumentation()
        let causes = SendableBox<[CancellationCause?]>([])
        let supervisor = Supervisor(label: "test", backoff: .immediate) {
            Child("tap", heartbeat: .init(interval: .seconds(5), misses: 2, grace: .seconds(10))) { _ in
                _ = script.started("tap")
                do { try await Task.sleep(for: .seconds(3600)) }   // never beats
                catch { causes.mutate { $0.append(CancellationCause.current) }; throw error }
            }
        }
        let run = Task { try await withTestAmbient(clock: clock, events: events) { try await supervisor.run() } }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(10))   // grace
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(5))    // first miss
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(5))    // second miss: hung
        await eventually { script.count("tap") >= 2 }
        #expect(script.count("tap") == 2)
        #expect(events.names.contains("supervisor.child_hung"))
        #expect(causes.value.first == .childHung, "cleanup can tell a hang from a shutdown")
        run.cancel()
        _ = try? await run.value
        #expect(causes.value.last == .supervisorStopped)
    }

    /// A cancellation the supervisor did not ask for means the child stopped
    /// when it should not have: a failure, restarted, and reported as what
    /// it was rather than as an ordinary error.
    @Test(.failureMode("design/09", "a child is cancelled by something else"))
    func aChildCancelledFromOutsideIsAFailureReportedAsSuch() async throws {
        let events = RecordingInstrumentation()
        let script = Script()
        let supervisor = Supervisor(label: "test", backoff: .immediate) {
            Child("sync") { _ in
                if script.started("sync") == 1 { throw CancellationError() }   // e.g. a session invalidated elsewhere
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let run = Task { try await withTestAmbient(clock: TestClock(), events: events) { try await supervisor.run() } }
        #expect(await eventually { script.count("sync") == 2 }, "restarted like any failure")
        let exited = events.events(named: "supervisor.child_exited").first
        #expect(exited?.level == .warning)
        #expect(exited?.fields.first { $0.key == "cause" }.map { "\($0.value)" } == "cancelled_from_outside")
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
        await eventually { beat.value != nil }
        for _ in 0..<5 {
            await clock.waitForSleepers(count: 1)
            beat.value?.beat()
            await clock.advance(by: .seconds(5))
        }
        #expect(script.count("tap") == 1)
        run.cancel()
        _ = try? await run.value
    }

    @Test(.failureMode("design/09", "the supervisor's task is cancelled")) func cancellingTheSupervisorStopsChildrenWithACause() async throws {
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

    @Test(.failureMode("design/09", "a child ignores cancellation on shutdown")) func aChildThatIgnoresCancellationIsAbandonedAfterItsTimeout() async throws {
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

    /// Device pressure multiplies a restart delay, and the schedule's cap is
    /// the last word. Eight times thirty seconds would be four minutes; a
    /// schedule capped at thirty seconds waits thirty. An uncapped one-second
    /// delay, and one capped far above the stretch, wait eight.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/09", "the device is hot, saving power or short of memory"))
    func aStrugglingDeviceStretchesRestartDelaysWithoutPassingTheCap() async {
        let struggling = SystemConditions(memoryPressure: .critical, thermal: .critical, lowPowerMode: true)
        #expect(struggling.backoffFactor == 8)

        let atTheCap = await restartWait(backoff: .fixed(.seconds(30)).capped(at: .seconds(30)), conditions: struggling)
        #expect(atTheCap == .seconds(30), "eight times 30 s, held at the cap rather than 240 s")

        let underTheCap = await restartWait(backoff: .fixed(.seconds(1)).capped(at: .seconds(30)), conditions: struggling)
        #expect(underTheCap == .seconds(8), "the stretch still applies while the result is under the cap")

        let uncapped = await restartWait(backoff: .fixed(.seconds(1)), conditions: struggling)
        #expect(uncapped == .seconds(8), "an uncapped delay stretches with the device")
    }

    /// How long the supervisor actually sleeps before restarting one child
    /// that fails once, under `conditions`: the restart timer's deadline, which
    /// is also the delay `supervisor.child_restarting` records.
    private func restartWait(backoff: Schedule, conditions: SystemConditions) async -> Duration? {
        let clock = TestClock()
        let script = Script()
        let events = RecordingInstrumentation()
        let supervisor = Supervisor(
            label: "pressure",
            intensity: .init(maxRestarts: 4, within: .seconds(60)),
            backoff: backoff
        ) {
            Child("worker") { _ in
                if script.started("worker") == 1 { throw Crash() }
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let run = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await withAmbient({ $0.conditions = FixedConditions(conditions) }) {
                    try await supervisor.run()
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        let waiting = clock.pendingDeadlines.first.map { clock.now.duration(to: $0) }
        let recorded: Duration?
        if case .duration(let delay) = events.events(named: "supervisor.child_restarting").first?["delay"] {
            recorded = delay
        } else {
            recorded = nil
            Issue.record("supervisor.child_restarting did not record a delay")
        }
        #expect(waiting == recorded, "the sleep and the reported delay are the same wait")
        if let waiting {
            await clock.advance(by: waiting)
            #expect(await eventually { script.count("worker") == 2 }, "the child restarts when that wait elapses")
        }
        run.cancel()
        _ = try? await run.value
        return waiting
    }
}

@Suite("Supervisor: review fixes")
struct SupervisorReviewTests {
    struct Crash: Error {}

    /// Counts live instances of each child, to catch duplicates.
    final class Census: Sendable {
        let state = SendableBox<(live: [String: Int], peak: [String: Int], runs: [String: Int])>(([:], [:], [:]))
        func enter(_ name: String) {
            state.mutate { s in
                s.live[name, default: 0] += 1
                s.runs[name, default: 0] += 1
                s.peak[name] = max(s.peak[name] ?? 0, s.live[name]!)
            }
        }
        func leave(_ name: String) { state.mutate { $0.live[name, default: 0] -= 1 } }
    }

    @Test func restForOneNeverRunsTwoInstancesOfAChild() async throws {
        let census = Census()
        let aCrashes = SendableBox(0)
        func child(_ name: String, crashFirst: Bool, after delay: Duration) -> Child {
            Child(name) { _ in
                census.enter(name)
                defer { census.leave(name) }
                let run = census.state.value.runs[name] ?? 0
                if crashFirst && run == 1 {
                    try await Task.sleep(for: delay)
                    if name == "A" { aCrashes.mutate { $0 += 1 } }
                    throw Crash()
                }
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let supervisor = Supervisor(label: "rest", strategy: .restForOne, intensity: .init(maxRestarts: 10, within: .seconds(60)), backoff: .fixed(.milliseconds(40))) {
            child("A", crashFirst: true, after: .milliseconds(15))   // fails during B's restart delay
            child("B", crashFirst: true, after: .milliseconds(1))
            child("C", crashFirst: false, after: .zero)
        }
        let run = Task { try await supervisor.run() }
        await eventually { (census.state.value.runs["C"] ?? 0) >= 2 && aCrashes.value >= 1 }
        try await Task.sleep(for: .milliseconds(150))
        let peak = census.state.value.peak
        #expect(peak["B"] == 1 && peak["C"] == 1, "previously two instances of B and C ran at once: \(peak)")
        run.cancel()
        _ = try? await run.value
        let live = census.state.value.live
        #expect(live["B"] == 0 && live["C"] == 0, "no orphaned instances after the supervisor stops: \(live)")
    }

    @Test func aFinishedTransientChildIsNotResurrectedByAGroupRestart() async {
        let runs = SendableBox<[String: Int]>([:])
        let supervisor = Supervisor(label: "all", strategy: .oneForAll, intensity: .init(maxRestarts: 1, within: .seconds(60)), backoff: .immediate) {
            Child("done", restart: .transient) { _ in runs.mutate { $0["done", default: 0] += 1 } }
            Child("flaky", restart: .transient) { _ in
                let count = runs.mutate { $0["flaky", default: 0] += 1; return $0["flaky"]! }
                if count == 1 {
                    try await Task.sleep(for: .milliseconds(20))
                    throw Crash()
                }
            }
        }
        try? await supervisor.run()
        #expect(runs.value["done"] == 1, "previously the finished transient child ran again")
        #expect(runs.value["flaky"] == 2)
    }

    @Test(.timeLimit(.minutes(1))) func anEndedBackoffScheduleEscalates() async {
        let restarts = SendableBox(0)
        let supervisor = Supervisor(label: "bounded", intensity: .init(maxRestarts: .max, within: .seconds(60)), backoff: Schedule.delays([.milliseconds(1), .milliseconds(1)]).schedule) {
            Child("crashy") { _ in
                restarts.mutate { $0 += 1 }
                throw Crash()
            }
        }
        await #expect(throws: SupervisorEscalation.self) { try await supervisor.run() }
        #expect(restarts.value == 3, "two scheduled delays, then the schedule ends and the supervisor gives up")
    }

    @Test(.timeLimit(.minutes(1))) func aRestartIsDueFromTheDecisionNotFromWhenItsTimerRuns() async {
        let clock = TestClock()
        let script = SupervisorTests.Script()
        let events = RecordingInstrumentation()
        let supervisor = Supervisor(label: "test", backoff: .fixed(.seconds(2))) {
            Child("worker") { _ in
                if script.started("worker") == 1 { throw SupervisorTests.Crash() }
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let published = supervisor.events()
        let decided = Task {
            for await event in published {
                if case .restarting = event { return }
            }
        }
        let run = Task { try await withTestAmbient(clock: clock, events: events) { try await supervisor.run() } }
        await decided.value
        // At once: no waiting for the timer's task to register its sleep.
        await clock.advance(by: .seconds(2))
        #expect(await eventually { script.count("worker") == 2 })
        run.cancel()
        _ = await run.result
    }

    @Test(.timeLimit(.minutes(1))) func heartbeatChecksFallOnFixedInstantsFromTheStart() async {
        let clock = TestClock()
        let script = SupervisorTests.Script()
        let supervisor = Supervisor(label: "test", backoff: .immediate) {
            Child("tap", heartbeat: .init(interval: .seconds(5), misses: 1, grace: .seconds(10))) { _ in
                _ = script.started("tap")
                try await Task.sleep(for: .seconds(3600))   // never beats
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }
        #expect(await eventually { script.count("tap") == 1 })
        // Grace ends at 10 s and the first check is at 15 s, both counted
        // from the start: one jump past both finds the child hung.
        await clock.advance(by: .seconds(15))
        #expect(await eventually { script.count("tap") == 2 })
        run.cancel()
        _ = await run.result
    }

    @Test(.timeLimit(.minutes(1))) func childrenDoNotInheritTheCallersDeadline() async throws {
        let sawDeadline = SendableBox<Bool?>(nil)
        let supervisor = Supervisor(label: "test") {
            Child("probe", restart: .temporary) { _ in
                sawDeadline.mutate { $0 = Deadline.current != nil }
            }
        }
        try await Deadline.$stored.withValue(.after(.seconds(600))) {
            try await supervisor.run()
        }
        #expect(sawDeadline.value == false)
    }

    @Test(.timeLimit(.minutes(1))) func aSupervisorWithNoChildrenReturns() async throws {
        let supervisor = Supervisor(label: "empty") {}
        try await supervisor.run()
    }

    @Test(.timeLimit(.minutes(1))) func theEventStreamFinishesWithTheRun() async throws {
        let supervisor = Supervisor(label: "once") {
            Child("once", restart: .temporary) { _ in }
        }
        let events = supervisor.events()
        let collected = Task { () -> Int in
            var count = 0
            for await _ in events { count += 1 }
            return count
        }
        try await supervisor.run()
        #expect(await collected.value >= 2)
        var late = supervisor.events().makeAsyncIterator()
        #expect(await late.next() == nil, "a stream made after the run finishes at once")
    }

    /// A UI and a parent both watching: each stream gets every event, not a
    /// share of them.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/09", "two observers watch the supervisor"))
    func everyEventsStreamSeesEveryEvent() async throws {
        let supervisor = Supervisor(label: "watched") {
            Child("once", restart: .temporary) { _ in }
        }
        let first = supervisor.events()
        let second = supervisor.events()
        let collectFirst = Task { await first.reduce(into: [SupervisorEvent]()) { $0.append($1) } }
        let collectSecond = Task { await second.reduce(into: [SupervisorEvent]()) { $0.append($1) } }
        try await withTestAmbient(clock: TestClock()) { try await supervisor.run() }
        let expected: [SupervisorEvent] = [.started(child: "once"), .exited(child: "once", failed: false), .stopped]
        #expect(await collectFirst.value == expected)
        #expect(await collectSecond.value == expected)
    }
}
