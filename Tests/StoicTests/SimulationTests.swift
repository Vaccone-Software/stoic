@testable import Stoic
import StoicTesting
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
        let run = try await simulate(seed: 0) { _ in
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
        // Scheduling alone never makes the finalizer slow.
        try await simulate(seeds: 0..<200, faults: .none, Self.closesBeforeTheScopeReturns)
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
