@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// When a reconciler's loop passes (design/30, Triggers, the schedule, and
/// when a pass runs), in simulations: virtual time moves only when everything
/// is asleep, so each pass runs exactly when it is due.
@Suite("Reconciler loop")
struct ReconcilerLoopTests {
    /// What a side was asked, and when, on the simulation's clock.
    final class ReadLog: Sendable {
        private let reads = Mutex<[(at: Duration, scope: ReconcileScope<String>)]>([])

        func record(_ scope: ReconcileScope<String>, at clock: TestClock) {
            reads.withLock { $0.append((clock.now.offset, scope)) }
        }

        var times: [Duration] { reads.withLock { $0.map(\.at) } }
        var scopes: [ReconcileScope<String>] { reads.withLock { $0.map(\.scope) } }
    }

    /// Logs every read of `side` (the truth: one per pass that gets that far).
    static func logging(_ side: Side, on clock: TestClock) async -> ReadLog {
        let log = ReadLog()
        await side.intercept { call in
            if case .read(let scope) = call { log.record(scope, at: clock) }
        }
        return log
    }

    /// `body` while `reconciler` runs; the loop is cancelled after it.
    static func whileRunning<R: Sendable>(
        _ reconciler: Reconciler<String>, _ body: @Sendable () async throws -> R
    ) async throws -> R {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await reconciler.run() }
            let result = try await body()
            group.cancelAll()
            return result
        }
    }

    static let minute = Duration.seconds(60)

    @Test(.failureMode("design/30", "the truth cannot be read"))
    func anUnreadableTruthIsReadAgainAfterTheFailedPassBackoff() async throws {
        try await simulated { clock, _ in
            let truth = Side(entries(2), label: "truth")
            let derived = Side([:], label: "derived")
            await truth.inject(.failRead, times: 2)
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(.seconds(900)), policy: quickPolicy())
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .passes, count: 3)
            }
            // 30 s, then 60 s: an outage is not hammered.
            #expect(log.times == [.zero, .seconds(30), .seconds(90)])
            #expect(await derived.entries == entries(2))
        }
    }

    @Test func passesFollowTheScheduleAfterEachFullPassEnds() async throws {
        try await simulated { clock, _ in
            let truth = Side(entries(2), label: "truth")
            let derived = Side(entries(2), label: "derived")
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(Self.minute), policy: quickPolicy())
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .passes, count: 3)
            }
            #expect(log.times == [.zero, Self.minute, Self.minute * 2])
            #expect(log.scopes == [.all, .all, .all])
        }
    }

    @Test func aPassThatCorrectedIsVerifiedAfterVerifyAfter() async throws {
        try await simulated { clock, _ in
            let truth = Side(["a": 1, "b": 2], label: "truth")
            let derived = Side([:], label: "derived")
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(Self.minute), policy: quickPolicy())
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .passes, count: 2)
            }
            #expect(log.times == [.zero, .seconds(2)])
            #expect(log.scopes == [.all, .keys(["a", "b"])], "a scoped pass over what was just corrected")
            #expect(reconciler.status.phase == .converged)
        }
    }

    @Test(.failureMode("design/30", "keys are triggered during a pass"))
    func triggersDuringAPassAreFoldedIntoOneScopedPassAfterIt() async throws {
        try await simulated { clock, _ in
            let truth = Side(["a": 1], label: "truth")
            let derived = Side([:], label: "derived")
            await derived.slowWrites(by: .seconds(5))
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(.seconds(900)), policy: quickPolicy())
            try await Self.whileRunning(reconciler) {
                try await Ambient.sleep(for: .seconds(1))
                await truth.set("x", 24)
                reconciler.changed("x")
                try await Ambient.sleep(for: .seconds(1))
                await truth.set("y", 25)
                reconciler.changed(["y", "x"])
                await reconciler.progress.wait(for: .passes, count: 2)
            }
            #expect(log.times == [.zero, .seconds(5)], "the first pass ends at 5 s; the triggers were due at 3 s")
            #expect(log.scopes == [.all, .keys(["x", "y"])], "one scoped pass for both, after the current one")
        }
    }

    @Test func aTriggerWaitsForCoalesceToBeQuiet() async throws {
        try await simulated { clock, _ in
            let truth = Side([:], label: "truth")
            let derived = Side([:], label: "derived")
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(.seconds(900)), policy: quickPolicy())
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .sleeps, count: 1)
                for name in ["a", "b", "c"] {
                    reconciler.changed(name)   // a group sign-up of three, 0.5 s apart
                    try await Ambient.sleep(for: .milliseconds(500))
                }
                await reconciler.progress.wait(for: .passes, count: 2)
            }
            #expect(log.times == [.zero, .milliseconds(2_000)], "a second after the last")
            #expect(log.scopes.last == .keys(["a", "b", "c"]))
        }
    }

    @Test(.failureMode("design/30", "more keys are triggered than pendingKeys"))
    func tooManyTriggeredKeysBecomeAFullPass() async throws {
        try await simulated { clock, events in
            let truth = Side([:], label: "truth")
            let derived = Side([:], label: "derived")
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(
                SideSync(truth: truth, derived: derived), every: .fixed(.seconds(900)), policy: quickPolicy { $0.pendingKeys = 3 })
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .sleeps, count: 1)
                reconciler.changed(["a", "b", "c", "d", "e"])
                await reconciler.progress.wait(for: .passes, count: 2)
            }
            #expect(log.scopes == [.all, .all])
            #expect(log.times == [.zero, .seconds(1)])
            let event = try #require(events.events(named: "reconciler.pending_overflow").first)
            #expect(event["pending"]?.description == "5")
        }
    }

    @Test(.failureMode("design/30", "run() is not running when keys are triggered"))
    func triggersBeforeRunAreCoveredByItsFirstFullPass() async throws {
        try await simulated { clock, _ in
            let truth = Side(["a": 1, "b": 2], label: "truth")
            let derived = Side([:], label: "derived")
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(Self.minute), policy: quickPolicy())
            // A device suspended in the background: recorded, nothing runs.
            reconciler.changed(["a", "b"])
            reconciler.requestFullPass()
            try await Ambient.sleep(for: .seconds(30))
            #expect(log.times.isEmpty)
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .passes, count: 3)
            }
            #expect(log.scopes == [.all, .keys(["a", "b"]), .all], "the start, its verification, the schedule: no pass for the old triggers")
            #expect(log.times == [.seconds(30), .seconds(32), .seconds(90)])
        }
    }

    @Test(.failureMode("design/30", "a pass finds more differences than correctionsPerPass"))
    func deferredWorkFollowsAfterCoalesceAsAFullPass() async throws {
        try await simulated { clock, _ in
            let truth = Side(entries(7), label: "truth")
            let derived = Side([:], label: "derived")
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(
                SideSync(truth: truth, derived: derived), every: .fixed(.seconds(900)), policy: quickPolicy { $0.correctionsPerPass = 3 })
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .passes, count: 3)
            }
            #expect(log.times == [.zero, .seconds(1), .seconds(2)], "not after the schedule's fifteen minutes")
            #expect(log.scopes == [.all, .all, .all])
            #expect(await derived.entries == entries(7))
        }
    }

    @Test(.failureMode("design/30", "a pass reaches its deadline"))
    func aPassCutShortByItsDeadlineIsFollowedByAnother() async throws {
        try await simulated { clock, _ in
            let truth = Side(entries(4), label: "truth")
            let derived = Side([:], label: "derived")
            await derived.slowWrites(by: .seconds(4))
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(.seconds(900)), policy: quickPolicy {
                $0.concurrency = 1
                $0.passDeadline = .seconds(6)
            })
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .passes, count: 2)
            }
            #expect(log.times == [.zero, .seconds(7)], "cut at 6 s, again after coalesce")
            #expect(log.scopes == [.all, .all])
        }
    }

    @Test(.failureMode("design/30", "no full pass has finished for overdueAfter"))
    func aReconcilerThatCannotReadForHalfAnHourIsOverdueOnce() async throws {
        try await simulated { clock, events in
            let truth = Side(entries(2), label: "truth")
            let derived = Side([:], label: "derived")
            await truth.inject(.failRead, times: 1_000)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(.seconds(900)), policy: quickPolicy())
            let start = TestClock.wallClockStart
            try await Self.whileRunning(reconciler) {
                try await Ambient.sleep(for: .seconds(1_799))
                #expect(!reconciler.status.isOverdue(at: Moment.now))
                #expect(events.count("reconciler.overdue") == 0)
                try await Ambient.sleep(for: .seconds(2))
                #expect(reconciler.status.isOverdue(at: Moment.now))
                #expect(reconciler.status.overdueAt == start + .seconds(1_800))
                try await Ambient.sleep(for: .seconds(3_600))
            }
            #expect(events.count("reconciler.overdue") == 1, "once")
            let event = try #require(events.events(named: "reconciler.overdue").first)
            #expect(event.level == .warning)
            #expect(event["since"]?.description == "start")
            _ = clock
        }
    }

    @Test(.failureMode("design/30", "nextChange() or nextDue falls due"))
    func aPassRunsWhenTheTruthSaysItChangesBySelf() async throws {
        try await simulated { clock, _ in
            let truth = Side(entries(1), label: "truth")
            let derived = Side(entries(1), label: "derived")
            let log = await Self.logging(truth, on: clock)
            let due = TestClock.wallClockStart + .seconds(100)
            let reconciler = Reconciler(scripted(truth: truth, derived: derived, next: { due }), every: .fixed(.seconds(900)), policy: quickPolicy())
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .passes, count: 2)
            }
            #expect(log.times == [.zero, .seconds(100)])
        }
    }

    @Test(.failureMode("design/30", "a due moment is still not in the future after the pass it caused"))
    func aDueMomentThatDoesNotMoveIsIgnoredUntilTheSchedule() async throws {
        try await simulated { clock, events in
            let truth = Side(entries(1), label: "truth")
            let derived = Side(entries(1), label: "derived")
            let log = await Self.logging(truth, on: clock)
            let stuck = TestClock.wallClockStart - .seconds(10)
            let reconciler = Reconciler(scripted(truth: truth, derived: derived, next: { stuck }), every: .fixed(Self.minute), policy: quickPolicy())
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .passes, count: 4)
            }
            // The start, the one pass the due moment caused, then the schedule,
            // after which it may cause one pass again.
            #expect(log.times == [.zero, .zero, Self.minute, Self.minute])
            #expect(events.count("reconciler.due_ignored") == 2, "once per scheduled pass, never a spin")
        }
    }

    @Test(.failureMode("design/30", "the wall clock jumps"))
    func aJumpOfTheWallClockIsMetWhenTheLoopNextSleeps() async throws {
        try await simulated { clock, _ in
            let truth = Side(entries(1), label: "truth")
            let derived = Side(entries(1), label: "derived")
            let log = await Self.logging(truth, on: clock)
            let due = TestClock.wallClockStart + .seconds(3_600)
            let reconciler = Reconciler(
                scripted(truth: truth, derived: derived, next: { due }), every: .fixed(.seconds(1_000)), policy: quickPolicy())
            try await Self.whileRunning(reconciler) {
                try await Ambient.sleep(for: .seconds(60))
                clock.jumpWallClock(by: .seconds(1_800))   // a person sets the clock half an hour on
                await reconciler.progress.wait(for: .passes, count: 3)
            }
            // The scheduled pass at 1,000 s recomputes the wait: the moment is
            // 800 s away on the wall clock now, so it passes at 1,800 s, not 3,600.
            #expect(log.times == [.zero, .seconds(1_000), .seconds(1_800)])
        }
    }

    @Test(.failureMode("design/30", "the run loop is cancelled"))
    func cancellingTheLoopCancelsThePassInProgressAndThrowsCancellation() async throws {
        try await simulated { _, _ in
            let truth = Side(entries(4), label: "truth")
            let derived = Side([:], label: "derived")
            await derived.slowWrites(by: .seconds(5))
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy { $0.concurrency = 1 })
            let thrown = await withTaskGroup(of: (any Error)?.self) { group in
                group.addTask {
                    do throws(CancellationError) {
                        try await reconciler.run()
                        return nil
                    } catch {
                        return error
                    }
                }
                do {
                    try await Ambient.sleep(for: .seconds(12))
                } catch {
                    return CancellationError() as (any Error)?
                }
                group.cancelAll()
                return await group.next() ?? nil
            }
            #expect(thrown is CancellationError)
            #expect(await derived.entries.count == 2, "two writes finished; the third was cut off")
            #expect(reconciler.status.phase == .converging(differences: 4), "what it finished is reflected")
        }
    }

    @Test(.failureMode("design/30", "keys keep being triggered, never quiet for coalesce"))
    func triggersThatNeverGoQuietAreServedWithinCoalesceAtMost() async throws {
        try await simulated { clock, _ in
            let truth = Side([:], label: "truth")
            let derived = Side([:], label: "derived")
            let log = await Self.logging(truth, on: clock)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), every: .fixed(.seconds(900)), policy: quickPolicy())
            try await Self.whileRunning(reconciler) {
                await reconciler.progress.wait(for: .sleeps, count: 1)
                try await Ambient.sleep(for: .milliseconds(100))
                // A busy server: a key changes every 0.4 s, from 0.1 s to 10.1 s.
                for index in 0..<26 {
                    reconciler.changed(key(index))
                    try await Ambient.sleep(for: .milliseconds(400))
                }
                await reconciler.progress.wait(for: .passes, count: 3)
            }
            #expect(log.times == [.zero, .milliseconds(5_100), .milliseconds(10_300)], "5 s after the oldest trigger not yet served")
            #expect(log.scopes == [.all, .keys(Set((0..<13).map(key))), .keys(Set((13..<26).map(key)))])
        }
    }

    @Test(.failureMode("design/30", "a job's pass reaches its deadline"))
    func aJobCutOffByThePassDeadlineCouldNotReadAndTheLoopGoesOn() async throws {
        try await simulated { clock, events in
            let calls = Mutex(0)
            let reconciler = Reconciler<String>(
                name: "test.slow-job", every: .fixed(.seconds(900)), policy: quickPolicy { $0.passDeadline = .seconds(6) }
            ) { _ in
                let call = calls.withLock { count -> Int in
                    count += 1
                    return count
                }
                if call == 1 { try await Ambient.sleep(for: .seconds(60)) }
                return ReconcileOutcome(differences: 0, corrected: 0)
            }
            try await Self.whileRunning(reconciler) {
                try await Ambient.sleep(for: .seconds(10))
                #expect(reconciler.status.phase == .unreadable(.truth), "cut off at 6 s: nothing is known of what it did")
                try await Ambient.sleep(for: .seconds(30))
            }
            #expect(calls.withLock { $0 } == 2, "again after the failed pass backoff: the loop did not end")
            #expect(reconciler.status.phase == .converged)
            #expect(events.count("reconciler.unreadable") == 1)
            _ = clock
        }
    }

    @Test func aCorrectionThatCancelsItselfIsAFailureThatWaitsItsBackoff() async throws {
        try await simulated { clock, _ in
            let attempts = Mutex(0)
            let reconciliation = ScriptedReconciliation(
                truth: { _, _ in ["a": 1] }, derived: { _, _ in [:] },
                apply: { _, _ in
                    attempts.withLock { $0 += 1 }
                    // As awaiting a cached task that was cancelled long ago does.
                    throw CancellationError()
                })
            let reconciler = Reconciler(reconciliation, every: .fixed(.seconds(900)), policy: quickPolicy())
            let report = try await reconciler.pass()
            #expect(report.failed == 1)
            #expect(report.deferred == 0, "not cut short: nothing cut it")
            #expect(report.outcome == .partial)
            try await Self.whileRunning(reconciler) {
                try await Ambient.sleep(for: .seconds(60))
            }
            // 1 s, 2 s, 4 s, then 8 s apart: a correction on its backoff, never a pass every second.
            #expect(attempts.withLock { $0 } <= 12, "\(attempts.withLock { $0 }) attempts in a minute")
            #expect(reconciler.status.stuck.map(\.key) == ["a"])
            _ = clock
        }
    }
}
