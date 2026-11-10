@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// Convergence as a property (design/30, Testing): from any derived state,
/// under any interleaving of injected failures and crashes, repeated passes
/// reach the truth; no pass removes anything when the truth could not be
/// read; no pass removes more than the guard allows without a confirmation
/// that names its hold. And the harness is shown to catch reconcilers built
/// with each guarantee switched off.
@Suite("Reconciler convergence")
struct ReconcilerPropertyTests {
    @Test func everySeedConvergesAndNoPassIsUnsafe() async throws {
        var failures: [String] = []
        for seed in 0..<UInt64(500 * testScale) {
            if let violation = try await Self.explore(seed: seed, faults: []) { failures.append("seed \(seed): \(violation)") }
            if failures.count >= 3 { break }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// The safety properties on a starved scheduler: timers fire early, while
    /// work is still runnable, so deadlines land in the middle of reads and
    /// writes.
    @Test func noPassIsUnsafeWhenDeadlinesLandMidWrite() async throws {
        var failures: [String] = []
        for seed in 0..<UInt64(200 * testScale) {
            if let violation = try await Self.explore(seed: seed, faults: [], converges: false) { failures.append("seed \(seed): \(violation)") }
            if failures.count >= 3 { break }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Each defect must be caught by some seed: a harness that passes a broken
    /// reconciler proves nothing.
    @Test(arguments: [
        ("removes on a failed truth read", ReconcilerFaults.removesOnFailedTruthRead),
        ("treats an empty truth as true", ReconcilerFaults.treatsEmptyTruthAsTrue),
        ("lets passes overlap", ReconcilerFaults.letsPassesOverlap),
        ("does not verify", ReconcilerFaults.doesNotVerify),
    ])
    func aReconcilerWithADefectFailsTheHarness(_ name: String, _ faults: ReconcilerFaults) async throws {
        var caught: String?
        for seed in 0..<UInt64(500 * testScale) {
            caught = try await Self.explore(seed: seed, faults: faults)
            if caught != nil { break }
        }
        #expect(caught != nil, "the harness never caught a reconciler that \(name)")
    }

    // MARK: The harness

    /// One explored run: the first safety violation, or a failure to converge,
    /// as words; `nil` when the run was clean.
    ///
    /// Convergence is checked with timers that fire only when everything
    /// sleeps: with early timers a pass's deadline can land in the middle of
    /// any write, as on a starved CPU, every pass can be cut short, and
    /// "within 5 passes" would measure the scheduler. With `converges: false`
    /// the run has early timers and only the safety properties are checked.
    static func explore(seed: UInt64, faults: ReconcilerFaults, converges: Bool = true) async throws -> String? {
        try await simulate(seed: seed, faults: .standard, schedule: SimulationSchedule(.portfolio, earlyTimers: !converges)) { _ in
            await Exploration(seed: seed, faults: faults, converges: converges).run()
        }.value
    }

    /// Where a crash happens: a side call of the pass in flight, which the
    /// sides' interceptor cancels it at.
    final class CrashSwitch: Sendable {
        private struct State {
            var at: Int?
            var calls = 0
            var task: Task<ReconcilePassReport<String>, any Error>?
        }

        private let state = Mutex(State())

        func arm(_ at: Int?, _ task: Task<ReconcilePassReport<String>, any Error>?) {
            state.withLock { $0 = State(at: at, calls: 0, task: task) }
        }

        func called() {
            let crash = state.withLock { state -> Task<ReconcilePassReport<String>, any Error>? in
                state.calls += 1
                return state.calls == state.at ? state.task : nil
            }
            crash?.cancel()
        }
    }

    /// One seed's run: a truth of 0 to 60 keys, a derived side that overlaps
    /// it, misses keys, has extra keys and holds wrong values, and a fault
    /// script over the first 20 passes.
    final class Exploration: Sendable {
        let faults: ReconcilerFaults
        let converges: Bool
        let truth: Side
        let derived: Side
        let policy: ReconcilePolicy
        let random: Mutex<SeededGenerator>
        let crash = CrashSwitch()

        init(seed: UInt64, faults: ReconcilerFaults, converges: Bool) {
            self.faults = faults
            self.converges = converges
            var generator = SeededGenerator(seed: seed &* 0x9E37_79B9 &+ 1)
            func draw(_ range: Range<Int>) -> Int { Int.random(in: range, using: &generator) }
            var truth: [String: Int] = [:]
            for index in 0..<draw(0..<61) { truth[key(index)] = draw(0..<4) }
            var derived: [String: Int] = [:]
            for (name, value) in truth {
                switch draw(0..<20) {
                case 0..<12: derived[name] = value
                case 12..<15: derived[name] = value + 1
                default: break
                }
            }
            // Mostly a few extra keys; sometimes many, past the guard.
            let extras = draw(0..<4) == 0 ? draw(0..<40) : draw(0..<6)
            for index in 0..<extras { derived[key(100 + index)] = draw(0..<4) }
            self.truth = Side(truth, label: "truth")
            self.derived = Side(derived, label: "derived")
            policy = quickPolicy {
                $0.concurrency = draw(1..<5)
                $0.correctionsPerPass = draw(30..<200)
            }
            random = Mutex(generator)
        }

        func draw(_ range: Range<Int>) -> Int {
            random.withLock { Int.random(in: range, using: &$0) }
        }

        func fresh() -> Reconciler<String> {
            Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(.seconds(900)), policy: policy, clock: nil, faults: faults)
        }

        /// What the harness knows of one reconciler: the measure a scoped
        /// pass's guard uses, and a confirmation the next full pass may use.
        struct Knowledge {
            var lastFullDerived = 0
            var confirmed: Set<String>?
            /// An outside write since a full pass last read both sides.
            var outsideWrite = false
        }

        func run() async -> String? {
            let crash = crash
            await truth.intercept { _ in crash.called() }
            await derived.intercept { _ in crash.called() }
            var reconciler = fresh()
            var knowledge = Knowledge()

            for _ in 0..<20 {
                let crashAt = await script()
                if draw(0..<6) == 0 {
                    // Two passes asked for at once: they must queue.
                    for _ in 0..<8 { await derived.inject(.slow(.milliseconds(draw(1..<300)))) }
                    let both = reconciler
                    async let one = Self.result(both, .all)
                    async let two = Self.result(both, .all)
                    _ = await (one, two)
                    if await derived.concurrentWrites > 0 { return "two passes wrote one key at once" }
                    knowledge.confirmed = nil
                    continue
                }
                let scope: ReconcileScope<String> = draw(0..<3) == 0
                    ? .keys(Set((0..<draw(1..<6)).map { _ in key(draw(0..<110)) })) : .all
                let outcome = await pass(reconciler, scope: scope, crashAt: crashAt, knowledge: &knowledge)
                if let violation = outcome.violation { return violation }
                if outcome.crashed {
                    // A crash: a fresh reconciler over the same sides, keeping
                    // nothing of the old one.
                    reconciler = fresh()
                    knowledge = Knowledge(outsideWrite: true)
                }
                if draw(0..<5) == 0 {
                    let side = draw(0..<2) == 0 ? truth : derived
                    await side.set(key(draw(0..<110)), draw(0..<3) == 0 ? nil : draw(0..<4))
                    knowledge.outsideWrite = true
                }
            }

            // The faults stop. With the guard confirmed where a hold stands,
            // the derived side must equal the truth within 5 passes, and the
            // phase must be converged.
            await useUpFaults()
            for _ in 0..<5 {
                do {
                    try await Ambient.sleep(for: .seconds(10))   // every key's backoff has passed
                } catch {
                    return "cancelled"
                }
                if let hold = reconciler.status.hold {
                    do throws(ReconcileError) {
                        try reconciler.confirm(hold, by: ana, because: "the harness looked")
                        knowledge.confirmed = Set(hold.keys)
                    } catch {
                        return "confirming the current hold failed: \(error)"
                    }
                }
                let outcome = await pass(reconciler, scope: .all, crashAt: nil, knowledge: &knowledge)
                if let violation = outcome.violation { return violation }
                if reconciler.status.phase == .converged { break }
            }
            if await derived.concurrentWrites > 0 { return "two passes wrote one key at once" }
            guard converges else { return nil }
            let truthNow = await truth.entries
            let derivedNow = await derived.entries
            guard reconciler.status.phase == .converged, truthNow == derivedNow else {
                let differing = truthNow.filter { derivedNow[$0.key] != $0.value }.count
                let extra = derivedNow.keys.filter { truthNow[$0] == nil }.count
                return "did not converge within 5 passes: \(reconciler.status.phase), \(differing) differ, \(extra) extra, "
                    + "stuck \(reconciler.status.stuck.map(\.key)), hold \(reconciler.status.hold?.removals ?? 0)"
            }
            return nil
        }

        static func result(_ reconciler: Reconciler<String>, _ scope: ReconcileScope<String>) async -> Result<ReconcilePassReport<String>, ReconcileError> {
            do throws(ReconcileError) {
                return .success(try await reconciler.pass(scope))
            } catch {
                return .failure(error)
            }
        }

        /// This pass's faults; the side call at which it crashes, if it does.
        func script() async -> Int? {
            if draw(0..<8) == 0 { await truth.inject(.failRead) }
            if draw(0..<8) == 0 { await truth.inject(.readEmpty) }
            if draw(0..<10) == 0 { await derived.inject(.failRead) }
            if draw(0..<12) == 0 { await derived.inject(.readEmpty) }
            for _ in 0..<draw(0..<3) {
                let target: String? = draw(0..<2) == 0 ? nil : key(draw(0..<70))
                switch draw(0..<4) {
                case 0: await derived.inject(.failWrite(target))
                case 1: await derived.inject(.applyThenFail(target))
                case 2: await derived.inject(.dropWrite(target))
                default: await derived.inject(.slow(.milliseconds(draw(1..<500))))
                }
            }
            return draw(0..<6) == 0 ? draw(1..<12) : nil
        }

        /// Faults the script left unused would fire after the faults stop.
        func useUpFaults() async {
            await truth.clearFaults()
            await derived.clearFaults()
        }

        struct PassOutcome {
            var violation: String?
            var crashed = false
        }

        /// One pass, and every safety property over what it read and wrote.
        func pass(
            _ reconciler: Reconciler<String>, scope: ReconcileScope<String>, crashAt: Int?, knowledge: inout Knowledge
        ) async -> PassOutcome {
            let truthReads = await truth.reads.count
            let derivedReads = await derived.reads.count
            let writes = await derived.writes.count
            let task = Task<ReconcilePassReport<String>, any Error>(executorPreference: Ambient.current.taskExecutor) {
                try await reconciler.pass(scope)
            }
            crash.arm(crashAt, task)
            let result = await task.result
            crash.arm(nil, nil)
            var outcome = PassOutcome()
            if crashAt != nil, case .failure(let error) = result, error as? ReconcileError == .cancelled { outcome.crashed = true }

            // The last read of each side is the reading: an attempt cut off by
            // its own timeout is retried, and the retry's answer is the one used.
            let truthRead = await truth.reads.dropFirst(truthReads).last.map(\.result)
            let derivedRead = await derived.reads.dropFirst(derivedReads).last.map(\.result)
            let wrote = Array(await derived.writes.dropFirst(writes))
            // No write unless both sides were read.
            guard let desired = truthRead ?? nil, let actual = derivedRead ?? nil else {
                if !wrote.isEmpty { outcome.violation = "\(wrote.count) writes after a read that failed (\(scope))" }
                return outcome
            }
            let confirmed = scope == .all ? knowledge.confirmed : nil
            if scope == .all {
                knowledge.confirmed = nil
                knowledge.lastFullDerived = actual.count
                knowledge.outsideWrite = false
            }
            // Every write is one the plan of its own pass's readings asked for.
            for write in wrote {
                let asked = write.value.map { desired[write.key] == $0 && actual[write.key] != $0 }
                    ?? (desired[write.key] == nil && actual[write.key] != nil)
                if !asked {
                    outcome.violation = "wrote \(write.key)=\(String(describing: write.value)), which the readings did not ask for"
                    return outcome
                }
            }
            let removed = Set(wrote.filter { $0.value == nil }.map(\.key))
            // Nothing is removed after an empty full truth read, unconfirmed.
            if scope == .all, desired.isEmpty, !actual.isEmpty, confirmed == nil, !removed.isEmpty {
                outcome.violation = "\(removed.count) removals after an empty truth read"
                return outcome
            }
            // No more than the guard allows without a confirmation naming its hold.
            let measure = scope == .all ? actual.count : max(actual.count, knowledge.lastFullDerived)
            let limit = max(5, Int((0.10 * Double(measure)).rounded(.down)))
            let beyond = removed.subtracting(confirmed ?? [])
            if beyond.count > limit {
                outcome.violation = "\(beyond.count) removals of \(measure) read, past the guard's \(limit)"
                return outcome
            }
            // A status that says converged was read so: a full pass reports it
            // only from readings that agreed.
            if case .success = result, scope == .all, reconciler.status.phase == .converged, desired != actual {
                outcome.violation = "converged after a reading that found \(desired.count) wanted and \(actual.count) held, different"
            }
            return outcome
        }
    }
}
