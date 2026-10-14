import Darwin
@testable import Stoic
@testable import StoicTesting
import Synchronization
import Testing

actor SimulationLog {
    var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

enum SimulationPhase: Hashable, Sendable { case idle, on }

@Suite("Simulation")
struct SimulationTests {
    struct LostUpdate: Error, CustomStringConvertible {
        let count: Int
        var description: String { "expected 2, counted \(count)" }
    }

    /// Children, an actor, yields, a semaphore and a retry with jitter: a
    /// scenario whose ordering the seed decides, recorded as a trace.
    static func scenario(_ sim: SimulationContext) async throws -> [String] {
        let log = SimulationLog()
        let semaphore = AsyncSemaphore(permits: 2, label: "sim")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<4 {
                group.addTask {
                    try await semaphore.withPermit {
                        for step in 0..<3 {
                            await log.append("w\(worker).\(step)")
                            await Task.yield()
                        }
                    }
                }
            }
            group.addTask {
                let failures = SendableBox(0)
                _ = try await retry(.exponential(base: .milliseconds(100)).attempts(5)) { _ async throws -> Int in
                    if failures.mutate({ $0 += 1; return $0 }) < 4 { throw URLishError.timedOut }
                    await log.append("retry succeeded")
                    return 1
                }
            }
            try await group.waitForAll()
        }
        return await log.lines
    }

    enum URLishError: Error, Retryable {
        case timedOut
        var retryDecision: RetryDecision { .retry }
    }

    @Test func aSeedReplaysTheSameInterleavingExactly() async throws {
        let first = try await simulate(seed: 3, Self.scenario)
        let second = try await simulate(seed: 3, Self.scenario)
        #expect(first.value == second.value)
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.steps == second.steps)
        #expect(first.elapsed == second.elapsed)
    }

    @Test func differentSeedsExploreDifferentInterleavings() async throws {
        var traces: Set<[String]> = []
        for seed in 0..<20 as Range<UInt64> {
            traces.insert(try await simulate(seed: seed, Self.scenario).value)
        }
        #expect(traces.count > 5)
    }

    @Test func timeIsVirtualAndAdvancesWhenEverythingSleeps() async throws {
        let run = try await simulate(seed: 1) { _ in
            try await Ambient.sleep(for: .seconds(3600))
            try await withTimeout(.seconds(60)) { try await Ambient.sleep(for: .seconds(30)) }
        }
        #expect(run.elapsed == .seconds(3630))
    }

    @Test func findsALostUpdateAndNamesTheSeedThatReproducesIt() async throws {
        // Read, suspend, write: correct in almost every real run.
        let failure = await #expect(throws: SimulationFailure.self) {
            try await simulate(seeds: 0..<200) { _ in
                let counter = Mutex(0)
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<2 {
                        group.addTask {
                            let read = counter.withLock { $0 }
                            await Task.yield()
                            counter.withLock { $0 = read + 1 }
                        }
                    }
                }
                let count = counter.withLock { $0 }
                if count != 2 { throw LostUpdate(count: count) }
            }
        }
        #expect(failure?.reproduced == true)
        if case .threw(let error)? = failure?.kind {
            #expect(error is LostUpdate)
        } else {
            Issue.record("expected the body to throw, got \(String(describing: failure))")
        }
        #expect(failure?.description.contains("simulate(seed: \(failure?.seed ?? 0))") == true)
    }

    @Test func aDeadlockIsReportedAsAStallWithWhatIsStillRunning() async throws {
        let failure = await #expect(throws: SimulationFailure.self) {
            _ = try await simulate(seed: 0, limits: .init(stall: .milliseconds(100))) { _ in
                let machine = StateMachine<SimulationPhase, SimulationPhase>(initial: .idle, label: "stuck") { _, to in .to(to) }
                machine.whileIn(.on, label: "forever") { _ in
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }   // never resumed
                }
                machine.send(.on)
                // Waits on a value nothing will ever deliver.
                let nothing = AsyncStream<Int> { _ in }
                for await _ in nothing {}
            }
        }
        guard case .stalled(let running)? = failure?.kind else {
            Issue.record("expected a stall, got \(String(describing: failure))")
            return
        }
        #expect(running.contains { $0.label == "stuck.forever" })
    }

    @Test func aDeadlockInsideTheSimulationIsReportedAtOnce() async throws {
        // A minute of patience for outside work, but nothing from outside
        // ever took part, so there is nothing to wait for: the quiet limit
        // answers. The bound is far below the minute and far above a loaded
        // CI runner's scheduling delays, which a one-second bound was not.
        let clock = ContinuousClock()
        let start = clock.now
        let failure = await #expect(throws: SimulationFailure.self) {
            _ = try await simulate(seed: 0, limits: .init(stall: .seconds(60))) { _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        guard case .stalled? = failure?.kind else {
            Issue.record("expected a stall, got \(String(describing: failure))")
            return
        }
        #expect(start.duration(to: clock.now) < .seconds(20))
    }

    @Test func onceOutsideWorkHasTakenPartTheWaitIsTheLongOne() async throws {
        // A real sleep arrives from another thread: after it, the run knows
        // outside work exists, and a second, longer wait is not a stall.
        let run = try await simulate(seed: 0, limits: .init(stall: .seconds(5), quietStall: .milliseconds(250)), allowEscapes: true) { _ in
            try await Task.sleep(for: .milliseconds(1))
            try await Task.sleep(for: .milliseconds(700))
            return true
        }
        #expect(run.value)
    }

    @Test func aLivelockHitsTheVirtualTimeLimit() async throws {
        let failure = await #expect(throws: SimulationFailure.self) {
            _ = try await simulate(seed: 0, limits: .init(virtualTime: .seconds(60))) { _ in
                while true { try await Ambient.sleep(for: .seconds(1)) }
            }
        }
        guard case .virtualTimeLimit? = failure?.kind else {
            Issue.record("expected the time limit, got \(String(describing: failure))")
            return
        }
    }

    @Test func workStillRunningWhenTheBodyReturnsIsReported() async throws {
        let run = try await simulate(seed: 0, schedule: .uniform, allowEscapes: true) { _ in
            let machine = StateMachine<SimulationPhase, SimulationPhase>(initial: .idle, label: "left on") { _, to in .to(to) }
            machine.whileIn(.on, label: "humming") { _ in
                try? await Ambient.sleep(for: .seconds(3600))
            }
            machine.send(.on)
            await Task.yield()
            return machine
        }
        #expect(run.leftover.contains { $0.label == "left on.humming" })
        _ = run.value
    }

    // MARK: Review regressions

    @TaskLocal static var probe = "default"

    @Test func theBodyInheritsTheCallersTaskLocals() async throws {
        let run = try await Self.$probe.withValue("set by the test") {
            try await simulate(seed: 0) { _ in Self.probe }
        }
        #expect(run.value == "set by the test")
    }

    @Test func aBodyThatReturnsEndsTheRunWhateverItLeftRunning() async throws {
        let run = try await simulate(seed: 0, limits: .init(steps: 10_000)) { _ in
            Task(executorPreference: Ambient.current.taskExecutor) {
                while !Task.isCancelled { await Task.yield() }   // runnable forever
            }
            return 42
        }
        #expect(run.value == 42)
    }

    @Test func virtualTimeWaitsForWorkHandedOutside() async throws {
        // 10 ms of real blocking work under a 5 s (virtual) timeout: the
        // timeout must not fire before work that is nearly done in real time.
        for seed in 0..<10 as Range<UInt64> {
            let run = try await simulate(seed: seed, allowEscapes: true) { _ in
                try await abandoningAfter(.seconds(5), label: "sim.outside.\(seed)") { () throws(Never) -> Int in
                    usleep(10_000)   // stoic:allow(blocking-in-async): models blocking work, on a Dispatch thread
                    return 1
                }
            }
            #expect(run.value == 1)
        }
    }

    @Test func primitivesReplayInKeyOrder() async throws {
        // Supersede, cancel and resume many waiters at once: their order
        // comes from dictionaries, which must not leak into the schedule.
        @Sendable func scenario(_ sim: SimulationContext) async throws -> [Int] {
            let slot = TaskSlot<Int, Never>(label: "replay")
            let delivered = SendableBox<[Int]>([])
            for value in 0..<8 {
                slot.run { await Task.yield(); return value } deliver: { result in
                    delivered.mutate { $0.append(result.get()) }
                }
            }
            await slot.cancelAndWait()
            let flights = SingleFlight<Int, Int, Never>(label: "replay")
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { _ = try? await flights.run(1) { await Task.yield(); return 1 } }
                }
            }
            return delivered.value
        }
        let first = try await simulate(seed: 9, scenario)
        for _ in 0..<5 {
            let again = try await simulate(seed: 9, scenario)
            #expect(again.fingerprint == first.fingerprint)
            #expect(again.value == first.value)
        }
    }

    // MARK: Schedules

    /// One task must run `steps` yields ahead of another, which sits between
    /// two steps: uniform choice finds that with probability 2^-steps.
    static func runAheadNeedle(steps: Int) -> @Sendable (SimulationContext) async throws -> Void {
        { _ in
            let finished = Mutex(false)
            let sawFinished = Mutex(false)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for _ in 0..<steps { await Task.yield() }
                    finished.withLock { $0 = true }
                }
                group.addTask {
                    await Task.yield()
                    if finished.withLock({ $0 }) { sawFinished.withLock { $0 = true } }
                }
            }
            if sawFinished.withLock({ $0 }) { throw RanAhead() }
        }
    }

    struct RanAhead: Error {}

    @Test func uniformChoiceCannotFindARunAheadButThePortfolioDoes() async throws {
        let needle = Self.runAheadNeedle(steps: 20)
        // Twenty yields in a row for one task against one for the other.
        try await simulate(seeds: 0..<200, faults: .none, schedule: .uniform, needle)
        let failure = await #expect(throws: SimulationFailure.self) {
            try await simulate(seeds: 0..<200, faults: .none, schedule: SimulationSchedule(.portfolio, earlyTimers: false), needle)
        }
        #expect(failure?.reproduced == true)
        #expect(failure?.schedule.hasPrefix("pct(") == true)
        if case .threw(let error)? = failure?.kind { #expect(error is RanAhead) }
    }

    /// Lost update with some unrelated yields before the critical section.
    static func paddedLostUpdate(_ sim: SimulationContext) async throws {
        let counter = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<10 { await Task.yield() }
                    let read = counter.withLock { $0 }
                    await Task.yield()
                    counter.withLock { $0 = read + 1 }
                }
            }
        }
        if counter.withLock({ $0 }) != 2 { throw LostUpdate(count: counter.withLock { $0 }) }
    }

    @Test func theClassicsAreStillFoundQuickly() async throws {
        // Uniform finds it in the first handful of seeds; the portfolio,
        // half uniform, only a little later.
        for schedule in [SimulationSchedule.uniform, SimulationSchedule(.portfolio, earlyTimers: false)] {
            let failure = await #expect(throws: SimulationFailure.self) {
                try await simulate(seeds: 0..<40, faults: .none, schedule: schedule, Self.paddedLostUpdate)
            }
            #expect(failure != nil, "\(schedule)")
        }
    }

    @Test func aForcedScheduleIsUsedAndNamed() async throws {
        let uniform = try await simulate(seed: 3, schedule: .uniform) { _ in 1 }
        #expect(uniform.schedule == "uniform")
        let pct = try await simulate(seed: 3, schedule: .pct(depth: 3, horizon: 100)) { _ in 1 }
        #expect(pct.schedule == "pct(depth 3, horizon 100)")
        let timers = try await simulate(seed: 3, schedule: SimulationSchedule(.uniform, earlyTimers: true)) { _ in 1 }
        #expect(timers.schedule.hasPrefix("uniform"))
    }

    @Test func theSeedChoosesTheScheduleAndReplaysIt() async throws {
        var names: Set<String> = []
        for seed in 0..<16 as Range<UInt64> {
            let first = try await simulate(seed: seed, Self.scenario)
            let again = try await simulate(seed: seed, Self.scenario)
            #expect(first.schedule == again.schedule)
            #expect(first.fingerprint == again.fingerprint, "seed \(seed) \(first.schedule)")
            #expect(first.value == again.value, "seed \(seed) \(first.schedule)")
            names.insert(String(first.schedule.prefix { $0 != "," }))
        }
        #expect(names.contains("uniform"))
        for depth in 2...4 { #expect(names.contains { $0.hasPrefix("pct(depth \(depth)") }) }
    }

    @Test func theRuntimesJobDescriptionIsReadForTheTask() async throws {
        // The one place PCT depends on a format the runtime does not
        // promise. If it changes, the first job reads as unknown and the
        // run chooses uniformly.
        typealias Identity = SimulationExecutor.JobIdentity
        #expect(Identity(description: "UnownedJob(id: 12)") == .task(12))
        #expect(Identity(description: "UnownedJob(id: nil)") == .actor)
        #expect(Identity(description: "UnownedJob(task: 12)") == .unknown)
        #expect(Identity(description: "UnownedJob(id: twelve)") == .unknown)
        #expect(Identity(description: "") == .unknown)
        // And what the runtime says today parses.
        let executor = SimulationExecutor(seed: 0, strategy: .uniform)
        let task = Task(executorPreference: executor) { 1 }
        let job = try #require(executor.takeNext()).0
        let identity = Identity(job)
        executor.run(job)
        _ = await task.value
        guard case .task = identity else {
            Issue.record("a task's job did not read as a task's: \(identity)")
            return
        }
    }

    @Test func aSpinWaitDoesNotStarveItsPartnerUnderPriorities() async throws {
        // The spinner may have the top priority; its yields must still let
        // the task it waits for run, or this ends at the step limit.
        for seed in 0..<40 as Range<UInt64> {
            _ = try await simulate(seed: seed, limits: .init(steps: 100_000), faults: .none, schedule: .pct(depth: 2, horizon: 8)) { _ in
                let ready = Mutex(false)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { while !ready.withLock({ $0 }) { await Task.yield() } }
                    group.addTask {
                        for _ in 0..<5 { await Task.yield() }
                        ready.withLock { $0 = true }
                    }
                }
            }
        }
    }

    // MARK: Early timers

    @Test func aTimerFiringInTheMiddleOfWorkIsFoundOnlyByEarlyTimers() async throws {
        // A 1 ms timeout against ten steps of work that normally take
        // microseconds. Time passes only when everything is asleep, so
        // without early timers the work always wins.
        let body: @Sendable (SimulationContext) async throws -> Void = { _ in
            let expired = Mutex(false)
            let sawExpired = Mutex(false)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    try? await Ambient.sleep(for: .milliseconds(1))
                    expired.withLock { $0 = true }
                }
                group.addTask {
                    for _ in 0..<10 { await Task.yield() }
                    if expired.withLock({ $0 }) { sawExpired.withLock { $0 = true } }
                }
            }
            if sawExpired.withLock({ $0 }) { throw TimerFiredMidWork() }
        }
        try await simulate(seeds: 0..<300, faults: .none, schedule: .uniform, body)
        let failure = await #expect(throws: SimulationFailure.self) {
            try await simulate(seeds: 0..<300, faults: .none, schedule: SimulationSchedule(.uniform, earlyTimers: true), body)
        }
        #expect(failure?.reproduced == true)
        #expect(failure?.schedule.contains("early timers") == true)
        // The default schedule has them too.
        await #expect(throws: SimulationFailure.self) { try await simulate(seeds: 0..<300, faults: .none, body) }
    }

    struct TimerFiredMidWork: Error {}

    @Test func earlyTimersNeverStarveProgress() async throws {
        // Many timers, a body that needs them all, and a tight eight: the
        // budget runs out and the rest fire at quiet moments, as before.
        let run = try await simulate(seed: 5, schedule: SimulationSchedule(.uniform, earlyTimers: true)) { _ in
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<200 {
                    group.addTask {
                        for _ in 0..<5 { try? await Ambient.sleep(for: .milliseconds(1 + index % 7)); await Task.yield() }
                    }
                }
            }
            return true
        }
        #expect(run.value)
    }

    // MARK: Teardown

    final class Canary: Sendable {
        static let alive = Atomic<Int>(0)
        init() { Canary.alive.add(1, ordering: .relaxed) }
        deinit { Canary.alive.subtract(1, ordering: .relaxed) }
    }

    @Test func whatTheRunLeftAsleepIsUnwoundAndFreed() async throws {
        let before = Canary.alive.load(ordering: .relaxed)
        let cleaned = Mutex(false)
        let run = try await simulate(seed: 0, schedule: .uniform, allowEscapes: true) { _ in
            let canary = Canary()
            // A task of the user's, asleep on the simulation's clock …
            Task(executorPreference: Ambient.current.taskExecutor) {
                _ = canary
                try? await Ambient.sleep(for: .seconds(3600))
            }
            // … and a Stoic one, whose cleanup must get to run.
            let machine = StateMachine<SimulationPhase, SimulationPhase>(initial: .idle, label: "unwind") { _, to in .to(to) }
            machine.whileIn(.on, label: "humming") { _ in
                try? await Ambient.sleep(for: .seconds(3600))
                cleaned.withLock { $0 = true }
            }
            machine.send(.on)
            await Task.yield()
            await Task.yield()
            return machine
        }
        // Still reported as it was when the body returned …
        #expect(run.leftover.contains { $0.label == "unwind.humming" })
        // … but no longer running, and nothing it held is held.
        #expect(run.stuck.isEmpty)
        #expect(cleaned.withLock { $0 })
        #expect(!TaskLedger.current.contains { $0.label == "unwind.humming" })
        for _ in 0..<100 where Canary.alive.load(ordering: .relaxed) > before { await Task.yield() }
        #expect(Canary.alive.load(ordering: .relaxed) == before)
        _ = run.value
    }

    @Test func whatCannotBeUnwoundIsReportedAsStuck() async throws {
        let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
        let run = try await simulate(seed: 0, allowEscapes: true) { _ in
            let machine = StateMachine<SimulationPhase, SimulationPhase>(initial: .idle, label: "wedged") { _, to in .to(to) }
            machine.whileIn(.on, label: "forever") { _ in
                await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in waiters.withLock { $0.append(k) } }   // ignores cancellation
            }
            machine.send(.on)
            await Task.yield()
            await Task.yield()
            return machine
        }
        #expect(run.stuck.contains { $0.label == "wedged.forever" })
        // Let the test's own continuation go, so the task ends.
        for waiter in waiters.withLock({ let all = $0; $0 = []; return all }) { waiter.resume() }
        _ = run.value
    }

    // MARK: Fault points

    struct StillOpen: Error {}

    /// Assumes a resource is closed once its scope has returned — true unless
    /// its finalizer overruns its timeout and is abandoned, which happens only
    /// when the finalizer is slow to start: a rare path, in real runs.
    static func closesBeforeTheScopeReturns(_ sim: SimulationContext) async throws {
        let open = Mutex(true)
        await withScope { scope in
            scope.onExit(label: "close", timeout: .milliseconds(100)) { _ in open.withLock { $0 = false } }
        }
        if open.withLock({ $0 }) { throw StillOpen() }
    }

    @Test func faultPointsFindWhatSchedulingAloneCannot() async throws {
        // Choosing among runnable jobs never makes the finalizer slow.
        try await simulate(seeds: 0..<200, faults: .none, schedule: .uniform, Self.closesBeforeTheScopeReturns)
        // Fault points do, and the seed replays it.
        let failure = await #expect(throws: SimulationFailure.self) {
            try await simulate(seeds: 0..<200, Self.closesBeforeTheScopeReturns)
        }
        #expect(failure?.reproduced == true)
    }

    @Test func faultsReplayWithTheSeedAndAreCounted() async throws {
        var fired: [String: Int] = [:]
        for seed in 0..<30 as Range<UInt64> {
            let first = try await simulate(seed: seed, Self.scenario)
            let again = try await simulate(seed: seed, Self.scenario)
            #expect(first.fingerprint == again.fingerprint, "seed \(seed)")
            #expect(first.faultsFired == again.faultsFired, "seed \(seed)")
            fired.merge(first.faultsFired, uniquingKeysWith: +)
        }
        #expect(fired.keys.contains("retry.attempt"))
        #expect(fired.keys.contains("semaphore.arriving"))
    }

    @Test func noFaultsMeansNoneFire() async throws {
        let run = try await simulate(seed: 5, faults: .none, Self.scenario)
        #expect(run.faultsFired.isEmpty)
    }

    @Test(.stoic(seed: 11)) func theTraitsSeedIsTheDefault() async throws {
        let run = try await simulate { sim in sim.seed }
        #expect(run.value == 11)
    }
}
