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

    /// Waits on the children's starts themselves, not on real time: the
    /// test ends when middle and last have each started twice, however slow
    /// the machine (it once timed out under the Address Sanitizer).
    @Test func restForOneRestartsOnlyLaterChildren() async throws {
        let script = Script()
        let (starts, started) = AsyncStream<String>.makeStream()
        let supervisor = Supervisor(label: "test", strategy: .restForOne, backoff: .immediate) {
            Child("first") { _ in
                _ = script.started("first")
                started.yield("first")
                try await Task.sleep(for: .seconds(3600))
            }
            Child("middle") { _ in
                let run = script.started("middle")
                started.yield("middle")
                if run == 1 { throw Crash() }
                try await Task.sleep(for: .seconds(3600))
            }
            Child("last") { _ in
                _ = script.started("last")
                started.yield("last")
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let run = Task { try await withTestAmbient(clock: TestClock()) { try await supervisor.run() } }
        var seen: [String: Int] = [:]
        for await name in starts {
            seen[name, default: 0] += 1
            // Children start concurrently: first's one start may come after
            // the others' second, so it is waited for too.
            if seen["first", default: 0] >= 1 && seen["middle", default: 0] >= 2 && seen["last", default: 0] >= 2 { break }
        }
        // First never restarts: the restart that would have included it is
        // the one just seen.
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

    /// The child yields as it starts and the test advances at once: a grace
    /// read after the child could run would start at 15 s, not 0.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/09", "a child runs before its heartbeat monitor starts"))
    func heartbeatChecksFallOnFixedInstantsFromTheStart() async {
        let clock = TestClock()
        // Waits on the child's starts, not on real time: it once ran out of
        // `eventually`'s five seconds under a 300-repetition stress.
        let (starts, started) = AsyncStream<Void>.makeStream()
        let supervisor = Supervisor(label: "test", backoff: .immediate) {
            Child("tap", heartbeat: .init(interval: .seconds(5), misses: 1, grace: .seconds(10))) { _ in
                started.yield()
                try await Task.sleep(for: .seconds(3600))   // never beats
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }
        var next = starts.makeAsyncIterator()
        _ = await next.next()
        // Grace ends at 10 s and the first check is at 15 s, both counted
        // from the start: one jump past both finds the child hung, and the
        // child starts again.
        await clock.advance(by: .seconds(15))
        _ = await next.next()
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

/// What a slot is doing between a child stopping and its restart: the
/// decisions that must hold whichever way the run keeps that, on virtual time.
@Suite("Supervisor: restarts in waiting")
struct SupervisorWaitingTests {
    struct Crash: Error {}

    /// A decision about one child replaces a restart another slot is still
    /// waiting for: the older timer must not start the group a second time,
    /// or out of order.
    @Test(.timeLimit(.minutes(1))) func aNewDecisionSupersedesARestartStillWaiting() async {
        let clock = TestClock()
        let script = SupervisorTests.Script()
        let aFails = AsyncGate()
        let supervisor = Supervisor(
            label: "superseding", strategy: .restForOne,
            intensity: .init(maxRestarts: 10, within: .seconds(600)), backoff: .fixed(.seconds(10))
        ) {
            Child("A") { _ in
                if script.started("A") == 1 {
                    await aFails.wait()
                    throw Crash()
                }
                try await Task.sleep(for: .seconds(3600))
            }
            Child("B") { _ in
                _ = script.started("B")
                try await Task.sleep(for: .seconds(3600))
            }
            Child("C") { _ in
                if script.started("C") == 1 { throw Crash() }
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }
        // C failed at 0 s and waits to restart alone at 10 s.
        await clock.waitForSleepers(count: 1)
        let start = clock.now
        await clock.advance(by: .seconds(5))
        // A fails at 5 s: its group is A, B and C, due at 15 s, and C's own
        // timer goes with the decision it belonged to.
        aFails.open()
        #expect(await eventually { clock.pendingDeadlines == [start.advanced(by: .seconds(15))] })
        await clock.advance(by: .seconds(5))
        #expect(script.count("C") == 1, "the replaced timer's 10 s passed and started nothing")
        await clock.advance(by: .seconds(5))
        #expect(await eventually { script.count("A") == 2 && script.count("B") == 2 && script.count("C") == 2 })
        run.cancel()
        _ = await run.result
        #expect(script.count("A") == 2 && script.count("B") == 2 && script.count("C") == 2, "each started once by the group")
    }

    /// The siblings a group restart takes down go down newest first, and
    /// the child that failed is not stopped again.
    @Test(.timeLimit(.minutes(1))) func aGroupRestartStopsTheSiblingsNewestFirst() async {
        let script = SupervisorTests.Script()
        let stops = SendableBox<[String]>([])
        func child(_ name: String, crashes: Bool = false) -> Child {
            Child(name) { _ in
                let run = script.started(name)
                if crashes && run == 1 { throw Crash() }
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    stops.mutate { $0.append(name) }
                    throw error
                }
            }
        }
        let supervisor = Supervisor(label: "ordered", strategy: .oneForAll, backoff: .immediate) {
            child("a")
            child("b", crashes: true)
            child("c")
        }
        let run = Task { try await withTestAmbient(clock: TestClock()) { try await supervisor.run() } }
        #expect(await eventually { script.count("a") == 2 && script.count("b") == 2 && script.count("c") == 2 })
        #expect(stops.value == ["c", "a"], "newest first, the failed child left out")
        run.cancel()
        _ = await run.result
    }

    /// The supervisor is not done while a restart is still due: the children
    /// that finished for good do not end the run.
    @Test(.timeLimit(.minutes(1))) func aRestartStillWaitingKeepsTheRunGoingWhileTheOthersAreFinished() async throws {
        let clock = TestClock()
        let script = SupervisorTests.Script()
        let supervisor = Supervisor(label: "waiting", backoff: .fixed(.seconds(5))) {
            Child("done", restart: .transient) { _ in _ = script.started("done") }
            Child("flaky", restart: .transient) { _ in
                if script.started("flaky") == 1 { throw Crash() }
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(5))
        try await run.value
        #expect(script.count("flaky") == 2, "restarted after the wait, rather than abandoned with it")
        #expect(script.count("done") == 1, "and the finished child stayed finished")
    }

    /// Giving up cancels the restarts still waiting: nothing is left sleeping
    /// on the clock for a supervisor that has returned.
    @Test(.timeLimit(.minutes(1))) func anEscalationCancelsTheRestartsStillWaiting() async {
        let clock = TestClock()
        let script = SupervisorTests.Script()
        let aFails = AsyncGate()
        let supervisor = Supervisor(
            label: "giving-up", intensity: .init(maxRestarts: 1, within: .seconds(600)), backoff: .fixed(.seconds(10))
        ) {
            Child("A") { _ in
                _ = script.started("A")
                await aFails.wait()
                throw Crash()
            }
            Child("B") { _ in
                if script.started("B") == 1 { throw Crash() }
                try await Task.sleep(for: .seconds(3600))
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }
        await clock.waitForSleepers(count: 1)
        aFails.open()
        await #expect(throws: SupervisorEscalation.self) { try await run.value }
        #expect(clock.pendingDeadlines.isEmpty, "B's restart timer was cancelled with the run")
        #expect(script.count("B") == 1)
    }

    /// Cancelling the supervisor while a restart is waiting cancels the wait
    /// as well, and the child is not started again.
    @Test(.timeLimit(.minutes(1))) func cancellingTheSupervisorCancelsTheRestartsStillWaiting() async {
        let clock = TestClock()
        let script = SupervisorTests.Script()
        let supervisor = Supervisor(label: "cancelled", backoff: .fixed(.seconds(10))) {
            Child("worker") { _ in
                _ = script.started("worker")
                throw Crash()
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }
        await clock.waitForSleepers(count: 1)
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(clock.pendingDeadlines.isEmpty)
        #expect(script.count("worker") == 1)
    }
}
