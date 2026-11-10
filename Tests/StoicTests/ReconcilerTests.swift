@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// design/30's failure modes that one pass, or a few, prove: reading, the
/// plan, the guard and its holds, corrections and their keys, verification.
@Suite("Reconciler passes")
struct ReconcilerTests {
    // MARK: Reading

    @Test(.failureMode("design/30", "the truth cannot be read"))
    func anUnreadableTruthCorrectsAndRemovesNothing() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side(entries(3), label: "truth")
            let derived = Side(entries(5, value: { $0 + 100 }), label: "derived")
            await truth.inject(.failRead)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            await #expect(throws: ReconcileError.self) { try await reconciler.pass() }
            #expect(await derived.reads.isEmpty, "the derived side is never asked")
            #expect(await derived.writes.isEmpty)
            #expect(reconciler.status.phase == .unreadable(.truth))
            let failure = try #require(reconciler.status.unreadable)
            #expect(failure.errorType.hasSuffix("SimulatedSideError"))
            let event = try #require(events.events(named: "reconciler.unreadable").first)
            #expect(event["side"]?.description == "truth")
            #expect(event["reference"]?.description == failure.reference.description)
            #expect(event.level == .warning)
        }
    }

    @Test(.failureMode("design/30", "the derived side cannot be read"))
    func anUnreadableDerivedSideCorrectsNothing() async throws {
        try await onReconcilerTime { _, _ in
            let truth = Side(entries(3), label: "truth")
            let derived = Side([:], label: "derived")
            await derived.inject(.failRead)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            do throws(ReconcileError) {
                try await reconciler.pass()
                Issue.record("the pass must not succeed")
            } catch {
                guard case .unreadable(.derived, _) = error else { throw error }
            }
            #expect(await derived.writes.isEmpty)
            #expect(reconciler.status.phase == .unreadable(.derived))
        }
    }

    @Test(.failureMode("design/30", "a paged truth read fails partway"))
    func aPagedReadThatFailsPartwayIsUnreadableAndOneThatTruncatesIsHeld() async throws {
        try await onReconcilerTime { _, events in
            let derived = Side(entries(100), label: "derived")
            let pages = (0..<5).map { page in entries(20, offset: page * 20) }
            // The contract's read: every page, or a throw.
            let complete = ScriptedReconciliation(
                truth: { _, _ in
                    var all: [String: Int] = [:]
                    for (index, page) in pages.enumerated() {
                        if index == 2 { throw SimulatedSideError(label: "truth", what: "page 3 failed") }
                        all.merge(page) { $1 }
                    }
                    return all
                },
                derived: { scope, _ in try await derived.read(scope) },
                apply: { _, _ in Issue.record("nothing is corrected") })
            await #expect(throws: ReconcileError.self) { try await Reconciler(complete, policy: quickPolicy()).pass() }
            // A defective read that returns the two pages it got: the guard
            // limits what it can do.
            let truncating = ScriptedReconciliation(
                truth: { _, _ in pages[0].merging(pages[1]) { $1 } },
                derived: { scope, _ in try await derived.read(scope) },
                apply: { correction, _ in
                    if case .remove = correction { Issue.record("a truncated read removed \(correction.key)") }
                })
            let reconciler = Reconciler(truncating, policy: quickPolicy())
            let report = try await reconciler.pass()
            #expect(report.held == 60)
            #expect(report.outcome == .held)
            #expect(reconciler.status.hold?.removals == 60)
            #expect(events.count("reconciler.removals_held") == 1)
        }
    }

    @Test(.failureMode("design/30", "a scoped read returns a key outside its scope"))
    func aKeyOutsideTheScopeIsIgnoredAndReported() async throws {
        try await onReconcilerTime { _, events in
            let derived = Side(["a": 1, "z": 26], label: "derived")
            let applied = Mutex<[String]>([])
            let reconciliation = ScriptedReconciliation(
                truth: { _, _ in ["a": 2] },   // asked for "a" and "z", it also says nothing of "z": "z" is removable…
                derived: { _, _ in ["a": 1, "z": 26, "q": 17] },   // …and it returns "q", which nobody asked for
                apply: { correction, _ in applied.withLock { $0.append(correction.key) } })
            _ = derived
            let reconciler = Reconciler(reconciliation, policy: quickPolicy())
            let report = try await reconciler.pass(.keys(["a", "z"]))
            #expect(applied.withLock { $0.sorted() } == ["a", "z"], "q was outside the scope: ignored")
            #expect(report.differences == 2)
            let event = try #require(events.events(named: "reconciler.scope_exceeded").first)
            #expect(event.level == .error)
            #expect(event["side"]?.description == "derived")
            #expect(event["keys"]?.description == "1")
        }
    }

    // MARK: The guard

    @Test(.failureMode("design/30", "a full pass reads an empty truth and a non-empty derived side"))
    func anEmptyTruthIsHeldWithEveryKey() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side(entries(4), label: "truth")
            let derived = Side(entries(4, value: { $0 + 1 }), label: "derived")
            await truth.inject(.readEmpty)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            let report = try await reconciler.pass()
            // Four removals of four would pass the count of five: only the
            // empty-truth rule holds them.
            #expect(report.held == 4)
            #expect(report.outcome == .held)
            #expect(await derived.writes.isEmpty)
            let hold = try #require(reconciler.status.hold)
            #expect(hold.keys == entries(4).keys.sorted())
            #expect(hold.truthWasEmpty)
            #expect(hold.derivedCount == 4)
            #expect(reconciler.status.phase == .held(differences: 4))
            let event = try #require(events.events(named: "reconciler.removals_held").first)
            #expect(event["truth_empty"]?.description == "true")
        }
    }

    @Test func aScopedPassThatAddsToAHoldKeepsWhatTheFullPassFound() async throws {
        try await onReconcilerTime { _, _ in
            let truth = Side(entries(4), label: "truth")
            let derived = Side(entries(4), label: "derived")
            await truth.inject(.readEmpty)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            _ = try await reconciler.pass()
            #expect(reconciler.status.hold?.truthWasEmpty == true)
            // Six entries the truth never had appear and are triggered
            // together: past the count of five, so they join the hold.
            for index in 100..<106 { await derived.set(key(index), 1) }
            let report = try await reconciler.pass(.keys(Set((100..<106).map(key))))
            #expect(report.held == 6)
            let hold = try #require(reconciler.status.hold)
            #expect(hold.removals == 10)
            #expect(hold.truthWasEmpty, "the person confirming it is still told the truth read empty")
            #expect(hold.derivedCount == 6)
        }
    }

    @Test func aHeldPassStillAppliesItsCreatesAndUpdates() async throws {
        try await onReconcilerTime { _, _ in
            let truth = Side(entries(3), label: "truth")
            let derived = Side(entries(3, value: { $0 + 1 }).merging(entries(40, offset: 100)) { $1 }, label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            let report = try await reconciler.pass()
            #expect(report.applied == 3, "the three updates")
            #expect(report.held == 40)
            #expect(report.outcome == .held)
            #expect(await derived.writes.map(\.key).sorted() == entries(3).keys.sorted())
        }
    }

    @Test(.failureMode("design/30", "a pass would remove more than the guard allows"))
    func tooManyRemovalsAreHeld() async throws {
        try await onReconcilerTime { _, _ in
            let truth = Side(entries(899), label: "truth")
            let derived = Side(entries(1_000), label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            let report = try await reconciler.pass()
            #expect(report.held == 101, "101 of 1,000 is past 10%")
            #expect(await derived.entries.count == 1_000)
            #expect(reconciler.status.hold?.truthWasEmpty == false)
        }
    }

    @Test(.failureMode("design/30", "a pass removes within the guard"))
    func removalsWithinTheGuardComeAfterEveryCreateAndUpdate() async throws {
        try await onReconcilerTime { _, _ in
            var wanted = entries(910)
            wanted["k0000"] = -1   // an update
            wanted["new"] = 7      // a create, sorting after every k
            let truth = Side(wanted, label: "truth")
            var held = entries(1_000)
            for index in 900..<910 { held[key(index)] = nil }   // ten creates
            let derived = Side(held, label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy { $0.concurrency = 1 })
            let report = try await reconciler.pass()
            #expect(report.held == 0)
            #expect(report.applied == 12 + 90)
            let writes = await derived.writes
            let firstRemoval = try #require(writes.firstIndex { $0.value == nil })
            #expect(writes[..<firstRemoval].allSatisfy { $0.value != nil }, "every create and update first")
            #expect(writes[firstRemoval...].allSatisfy { $0.value == nil })
            #expect(writes[firstRemoval...].map(\.key) == (910..<1_000).map(key), "removes by key")
            #expect(await derived.entries == wanted)
        }
    }

    @Test(.failureMode("design/30", "a hold stands and the next pass computes the same removals"))
    func aStandingHoldIsNotReportedAgain() async throws {
        try await onReconcilerTime { clock, events in
            let truth = Side(entries(50), label: "truth")
            let derived = Side(entries(100), label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            try await reconciler.pass()
            let first = try #require(reconciler.status.hold)
            await clock.advance(by: .seconds(60))
            try await reconciler.pass()
            #expect(reconciler.status.hold == first, "the same hold, since the same moment")
            #expect(events.count("reconciler.removals_held") == 1)
            // Another set replaces it, and is reported again.
            await truth.set(key(0), nil)
            try await reconciler.pass()
            #expect(reconciler.status.hold?.removals == 51)
            #expect(events.count("reconciler.removals_held") == 2)
        }
    }

    @Test(.failureMode("design/30", "a hold stands and the truth read is mended"))
    func aMendedTruthReleasesTheHold() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side(entries(20), label: "truth")
            let derived = Side(entries(20), label: "derived")
            await derived.set("stale", 1)
            await truth.inject(.readEmpty)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            try await reconciler.pass()
            #expect(reconciler.status.hold?.removals == 21)
            let report = try await reconciler.pass()
            #expect(reconciler.status.hold == nil)
            #expect(report.applied == 1, "the one real removal, within the guard")
            #expect(await derived.entries == entries(20))
            #expect(events.count("reconciler.hold_released") == 1)
        }
    }

    @Test(.failureMode("design/30", "a person confirms the current hold"))
    func aConfirmationLetsTheNextFullPassRemoveTheHeldKeys() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side([:], label: "truth")
            let derived = Side(entries(30), label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            try await reconciler.pass()
            let hold = try #require(reconciler.status.hold)
            // Another key appears: the confirmed set plus as many as the guard allows.
            await derived.set("late", 1)
            try reconciler.confirm(hold, by: ana, because: "the test calendar was retired on purpose")
            let event = try #require(events.events(named: "reconciler.removals_confirmed").first)
            #expect(event["removals"]?.description == "30")
            let principal = try #require(event.fields.first { $0.key == "principal" })
            #expect(principal.privacy == .private)
            #expect(principal.value.description == "ana@kindora.example")
            #expect(event["evidence"]?.description.contains("PersonAtDevice") == true)
            #expect(!event.fields.contains { $0.value.description.contains("retired on purpose") }, "the reason is never in an event")
            #expect(reconciler.status.phase == .held(differences: 30), "the hold stands until the pass")

            let report = try await reconciler.pass()
            #expect(report.confirmation == "the test calendar was retired on purpose")
            // The truth is still empty: the one key beyond the confirmation is held again.
            #expect(report.applied == 30)
            #expect(await derived.entries == ["late": 1])
            #expect(reconciler.status.hold?.keys == ["late"])
            // The confirmation was used: the next pass holds as any would.
            let next = try await reconciler.pass()
            #expect(next.confirmation == nil)
            #expect(next.held == 1)
        }
    }

    @Test(.failureMode("design/30", "a person confirms a hold that has since changed"))
    func confirmingAStaleHoldIsRefused() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side(entries(10), label: "truth")
            let derived = Side(entries(40), label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            try await reconciler.pass()
            let seen = try #require(reconciler.status.hold)
            await truth.set(key(0), nil)
            try await reconciler.pass()
            #expect(throws: ReconcileError.holdChanged) { try reconciler.confirm(seen, by: ana, because: "looked fine") }
            #expect(events.count("reconciler.removals_confirmed") == 0)
            let report = try await reconciler.pass()
            #expect(report.held == 31, "nothing was let through")
            #expect(await derived.entries.count == 40)
        }
    }

    @Test(.failureMode("design/30", "the process relaunches while a hold stands"))
    func aRelaunchForgetsTheHoldAndHoldsAgain() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side([:], label: "truth")
            let derived = Side(entries(12), label: "derived")
            let first = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            try await first.pass()
            let hold = try #require(first.status.hold)
            try first.confirm(hold, by: ana, because: "confirmed before the relaunch")
            // A relaunch: nothing of the old reconciler is kept.
            let relaunched = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            #expect(relaunched.status.hold == nil)
            let report = try await relaunched.pass()
            #expect(report.held == 12)
            #expect(report.confirmation == nil)
            #expect(await derived.entries.count == 12)
            #expect(events.count("reconciler.removals_held") == 2)
        }
    }

    @Test(.failureMode("design/30", "two reconcilers run over one derived side"))
    func twoRunnersWasteWorkAndNeitherRemovesPastItsGuard() async throws {
        try await simulated { _, _ in
            let truth = Side(entries(10), label: "truth")
            let derived = Side(entries(10, value: { $0 + 1 }).merging(entries(10, offset: 500)) { $1 }, label: "derived")
            for _ in 0..<4 { await derived.inject(.slow(.milliseconds(10))) }
            let one = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            let two = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            async let first = one.pass()
            async let second = two.pass()
            let reports = try await [first, second]
            #expect(reports.allSatisfy { $0.held == 10 }, "ten of twenty is past the guard for both")
            #expect(await derived.entries.count == 20)
            // Their work is the same work twice; reading back settles it.
            #expect(reports.map(\.applied) == [10, 10])
            #expect(await derived.entries.filter { $0.key < "k0010" } == entries(10))
            try await one.pass(.keys(Set(entries(10).keys)))
            #expect(one.status.phase == .held(differences: 10))
        }
    }

    // MARK: Corrections

    @Test(.failureMode("design/30", "a correction fails"))
    func aFailedCorrectionWaitsItsBackoffAndStaysADifference() async throws {
        try await onReconcilerTime { clock, events in
            let truth = Side(["a": 1, "b": 2, "c": 3], label: "truth")
            let derived = Side([:], label: "derived")
            await derived.inject(.failWrite("b"))
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            let report = try await reconciler.pass()
            #expect(report.applied == 2)
            #expect(report.failed == 1)
            #expect(report.outcome == .partial)
            #expect(await derived.entries == ["a": 1, "c": 3], "the pass went on")
            let event = try #require(events.events(named: "reconciler.correction_failed").first)
            #expect(event.level == .notice)
            #expect(event["kind"]?.description == "create")
            #expect(event.fields.first { $0.key == "key" }?.privacy == .private)
            // Waiting: skipped, still a difference.
            let next = try await reconciler.pass()
            #expect(next.waiting == 1)
            #expect(next.applied == 0)
            #expect(reconciler.status.phase == .converging(differences: 1))
            await clock.advance(by: .seconds(1))
            let after = try await reconciler.pass()
            #expect(after.applied == 1, "its backoff of one second has passed")
            #expect(await derived.entries == ["a": 1, "b": 2, "c": 3])
        }
    }

    @Test(.failureMode("design/30", "a correction fails in stuckAfter passes in a row"))
    func aKeyThatKeepsFailingIsStuckOnceAndStillRetried() async throws {
        try await onReconcilerTime { clock, events in
            let truth = Side(["a": 1], label: "truth")
            let derived = Side([:], label: "derived")
            await derived.inject(.failWrite("a"), times: 5)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            for pass in 1...5 {
                try await reconciler.pass()
                if pass < 3 { #expect(reconciler.status.stuck.isEmpty, "pass \(pass)") }
                await clock.advance(by: .seconds(8))
            }
            #expect(events.count("reconciler.stuck") == 1, "reported once, when it became stuck")
            let stuck = try #require(reconciler.status.stuck.first)
            #expect(stuck.key == "a")
            #expect(stuck.kind == .create)
            #expect(stuck.passes == 5)
            guard case .failing(let failure) = stuck.reason else { Issue.record("\(stuck.reason)"); return }
            #expect(failure.errorType.hasSuffix("SimulatedSideError"))
            #expect(!failure.isDefect)
            #expect(reconciler.status.phase == .stuck(differences: 1))
            let event = try #require(events.events(named: "reconciler.stuck").first)
            #expect(event["passes"]?.description == "3")
            #expect(event["reason"]?.description == "failing")
            #expect(event["reference"]?.description != nil)
            // Still retried on its backoff: the sixth attempt succeeds.
            try await reconciler.pass()
            #expect(await derived.entries == ["a": 1])
        }
    }

    @Test(.failureMode("design/30", "a correction throws a Defect"))
    func aDefectMakesTheKeyStuckAtOnce() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side(["a": 1, "b": 2], label: "truth")
            let derived = Side([:], label: "derived")
            let reconciliation = scripted(truth: truth, derived: derived) { correction, _ in
                if correction.key == "a" { throw CorrectionBug() }
            }
            let reconciler = Reconciler(reconciliation, policy: quickPolicy())
            try await reconciler.pass()
            let stuck = try #require(reconciler.status.stuck.first)
            #expect(stuck.key == "a")
            #expect(stuck.passes == 1)
            guard case .failing(let failure) = stuck.reason else { Issue.record("\(stuck.reason)"); return }
            #expect(failure.isDefect)
            let event = try #require(events.events(named: "reconciler.stuck").first)
            #expect(event.level == .error)
            #expect(await derived.entries == ["b": 2])
        }
    }

    @Test(.failureMode("design/30", "a correction applies and then fails (an unknown outcome)"))
    func anUnknownOutcomeIsSettledByTheNextReading() async throws {
        try await onReconcilerTime { clock, _ in
            let truth = Side(["a": 1], label: "truth")
            let derived = Side([:], label: "derived")
            await derived.inject(.applyThenFail("a"))
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            let report = try await reconciler.pass()
            #expect(report.failed == 1)
            #expect(await derived.entries == ["a": 1], "it applied")
            await clock.advance(by: .seconds(1))
            let next = try await reconciler.pass()
            #expect(next.differences == 0, "the reading shows it applied; the plan follows from that")
            #expect(reconciler.status.phase == .converged)
            #expect(await derived.writes.count == 1, "never written again")
        }
    }

    @Test(.failureMode("design/30", "a correction succeeds and the next read still differs"))
    func aCorrectionThatDoesNotTakeIsStuckAfterThreeVerdicts() async throws {
        try await onReconcilerTime { clock, events in
            let truth = Side(["a": 1], label: "truth")
            let derived = Side([:], label: "derived")
            await derived.inject(.dropWrite("a"), times: 10)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            try await reconciler.pass()   // written, dropped
            #expect(reconciler.status.phase == .converging(differences: 1))
            // Each verdict takes two passes: one reads it back (did not take)
            // and holds it on its backoff; the next corrects it again.
            for pass in 0..<5 {
                await clock.advance(by: .seconds(8))
                try await reconciler.pass()
                if pass < 4 { #expect(reconciler.status.stuck.isEmpty, "pass \(pass)") }
            }
            let stuck = try #require(reconciler.status.stuck.first)
            #expect(stuck.reason == .doesNotTake)
            #expect(stuck.kind == .create)
            #expect(events.events(named: "reconciler.stuck").first?["reason"]?.description == "does_not_take")
        }
    }

    @Test(.failureMode("design/30", "a stuck key's correction later takes"))
    func aStuckKeyThatTakesIsUnstuck() async throws {
        try await onReconcilerTime { clock, events in
            let truth = Side(["a": 1], label: "truth")
            let derived = Side([:], label: "derived")
            await derived.inject(.failWrite("a"), times: 3)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            for _ in 0..<3 {
                try await reconciler.pass()
                await clock.advance(by: .seconds(8))
            }
            #expect(reconciler.status.stuck.count == 1)
            try await reconciler.pass()   // applies
            try await reconciler.pass()   // reads it back
            #expect(reconciler.status.stuck.isEmpty)
            #expect(reconciler.status.phase == .converged)
            let event = try #require(events.events(named: "reconciler.unstuck").first)
            #expect(event.fields.first { $0.key == "key" }?.privacy == .private)
        }
    }

    @Test(.failureMode("design/30", "a pass finds more differences than correctionsPerPass"))
    func theFirstCorrectionsByPlanOrderAreAppliedAndTheRestDeferred() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side(entries(5), label: "truth")
            let derived = Side([:], label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy {
                $0.correctionsPerPass = 3
                $0.concurrency = 1
            })
            let report = try await reconciler.pass()
            #expect(report.applied == 3)
            #expect(report.deferred == 2)
            #expect(report.outcome == .cutShort)
            #expect(await derived.writes.map(\.key) == (0..<3).map(key))
            #expect(events.count("reconciler.cut_short") == 1)
        }
    }

    @Test(.failureMode("design/30", "a pass reaches its deadline"))
    func aPassAtItsDeadlineStartsNoMoreAndCutsWhatIsInFlight() async throws {
        try await simulated { _, events in
            let truth = Side(entries(6), label: "truth")
            let derived = Side([:], label: "derived")
            // Each write takes 4 s; two at once; the pass has 6 s.
            await derived.slowWrites(by: .seconds(4))
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy {
                $0.concurrency = 2
                $0.passDeadline = .seconds(6)
            })
            let report = try await reconciler.pass()
            #expect(report.outcome == .cutShort)
            #expect(report.applied == 2, "two landed at 4 s")
            #expect(report.failed == 0, "cut off is not failed")
            #expect(report.deferred == 4, "two cut off in flight at 6 s, two never started")
            #expect(await derived.entries.count == 2)
            #expect(events.events(named: "reconciler.cut_short").first?["deadline"]?.description == "true")
            #expect(reconciler.status.phase == .converging(differences: 6))
        }
    }

    @Test(.failureMode("design/30", "a read or a correction hangs"))
    func aHangingReadEndsAtItsOperationsOwnDeadline() async throws {
        try await simulated { clock, _ in
            let truth = Side(entries(2), label: "truth")
            let derived = Side([:], label: "derived")
            await truth.inject(.slow(.seconds(86_400)), times: 10)
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            let limit = SideSync.readsTruth.policy(at: Urgency.current).deadline
            let started = clock.now
            let outcome: ReconcileError?
            do throws(ReconcileError) {
                try await reconciler.pass()
                outcome = nil
            } catch {
                outcome = error
            }
            guard case .unreadable(.truth, _)? = outcome else { Issue.record("\(String(describing: outcome))"); return }
            #expect(started.duration(to: clock.now) <= limit, "the read's own deadline, inside the pass's ten minutes")
            // A hung correction ends the same way, at its own deadline.
            let slowWrites = Side([:], label: "derived")
            await slowWrites.slowWrites(by: .seconds(86_400))
            let writer = Reconciler(SideSync(truth: Side(["a": 1], label: "truth"), derived: slowWrites), policy: quickPolicy())
            let writing = clock.now
            let report = try await writer.pass()
            #expect(writing.duration(to: clock.now) <= SideSync.corrects.policy(at: Urgency.current).deadline)
            #expect(report.failed == 1)
            #expect(report.outcome == .partial)
        }
    }

    @Test(.failureMode("design/30", "a correction is retried within one pass"))
    func everyAttemptOfOneCorrectionSendsTheSameKey() async throws {
        try await simulated { _, _ in
            let truth = Side(["a": 1, "b": 2], label: "truth")
            let derived = Side([:], label: "derived")
            let keys = Mutex<[String: [IdempotencyKey]]>([:])
            let reconciliation = scripted(truth: truth, derived: derived) { correction, attempt in
                let seen = keys.withLock { keys in
                    keys[correction.key, default: []].append(attempt.idempotencyKey)
                    return keys[correction.key, default: []].count
                }
                if seen < 3 { throw Flaky() }
            }
            let reconciler = Reconciler(reconciliation, policy: quickPolicy())
            let report = try await reconciler.pass()
            #expect(report.applied == 2)
            let sent = keys.withLock { $0 }
            #expect(sent["a"]?.count == 3)
            #expect(Set(sent["a"] ?? []).count == 1, "one key across the correction's attempts")
            #expect(Set(sent["b"] ?? []).count == 1)
            #expect(sent["a"]?.first != sent["b"]?.first, "each correction its own")
        }
    }

    @Test(.failureMode("design/30", "the same difference is corrected again in a later pass"))
    func aLaterPassCorrectsUnderANewKeyFromANewReading() async throws {
        try await onReconcilerTime { clock, _ in
            let truth = Side(["a": 1], label: "truth")
            let derived = Side([:], label: "derived")
            await derived.inject(.failWrite("a"))
            let keys = Mutex<[IdempotencyKey]>([])
            let reconciliation = scripted(truth: truth, derived: derived) { _, attempt in
                keys.withLock { $0.append(attempt.idempotencyKey) }
            }
            let reconciler = Reconciler(reconciliation, policy: quickPolicy())
            try await reconciler.pass()
            await truth.set("a", 2)   // the truth moved meanwhile
            await clock.advance(by: .seconds(1))
            try await reconciler.pass()
            let sent = keys.withLock { $0 }
            #expect(sent.count == 2)
            #expect(sent[0] != sent[1])
            #expect(await derived.writes.map(\.value) == [2], "from the new reading")
        }
    }

    @Test func aCorrectionsKeyIsThePassKeyAndItsPosition() {
        let pass = IdempotencyKey(rawValue: "00112233445566778899aabbccddeeff")
        // Frozen: a change of construction is a reviewed diff (design/30, As built).
        #expect(IdempotencyKey.reconciliation(pass: pass, position: 0).rawValue == "0c4804553527e1c49e1cd8fed0e0d54b")
        #expect(IdempotencyKey.reconciliation(pass: pass, position: 1).rawValue == "5537be575b75a093e304b3500f92d0f0")
        #expect(IdempotencyKey.reconciliation(pass: pass, position: 0) != IdempotencyKey.reconciliation(pass: pass, position: 1))
        let other = IdempotencyKey(rawValue: "ffeeddccbbaa99887766554433221100")
        #expect(IdempotencyKey.reconciliation(pass: other, position: 0) != IdempotencyKey.reconciliation(pass: pass, position: 0))
        #expect(IdempotencyKey.reconciliation(pass: pass, position: 0) != IdempotencyKey.lifecycle(record: pass, entry: 0, position: 0))
    }

    // MARK: Convergence

    @Test(.failureMode("design/30", "a full pass finds no difference"))
    func aCleanFullPassIsConvergedAtItsReadingsMoment() async throws {
        try await onReconcilerTime { clock, events in
            let truth = Side(entries(3), label: "truth")
            let derived = Side(entries(3), label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            #expect(reconciler.status.phase == .starting)
            await clock.advance(by: .seconds(5))
            let report = try await reconciler.pass()
            #expect(report.outcome == .clean)
            #expect(reconciler.status.phase == .converged)
            #expect(reconciler.status.lastConverged == TestClock.wallClockStart + .seconds(5))
            #expect(reconciler.status.lastFullPass == TestClock.wallClockStart + .seconds(5))
            #expect(events.count("reconciler.converged") == 1)
            try await reconciler.pass()
            #expect(events.count("reconciler.converged") == 1, "only when the phase changed")
        }
    }

    @Test(.failureMode("design/30", "a pass applies every correction"))
    func appliedCorrectionsAreConvergingUntilReadBack() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side(["a": 1, "b": 2], label: "truth")
            let derived = Side([:], label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            try await reconciler.pass()
            #expect(reconciler.status.phase == .converging(differences: 2), "a reading has not seen them yet")
            #expect(reconciler.status.lastConverged == nil)
            #expect(events.count("reconciler.converged") == 0)
            try await reconciler.pass(.keys(["a", "b"]))   // the verification pass's reading
            #expect(reconciler.status.phase == .converged)
            #expect(reconciler.status.lastConverged != nil)
        }
    }

    @Test(.failureMode("design/30", "something else writes to the derived side"))
    func anOutsideWriteIsCorrectedBackAndReportedAsDrift() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side(entries(4), label: "truth")
            let derived = Side(entries(4), label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            try await reconciler.pass()
            #expect(reconciler.status.phase == .converged)
            await derived.set(key(1), 99)   // a coordinator edits the calendar by hand
            let report = try await reconciler.pass()
            #expect(report.applied == 1)
            #expect(await derived.entries == entries(4), "the truth wins")
            let drift = try #require(events.events(named: "reconciler.drift_found").first)
            #expect(drift.level == .notice)
            #expect(drift["differences"]?.description == "1")
        }
    }

    @Test(.failureMode("design/30", "a trigger is missed"))
    func aMissedTriggerIsFoundByTheNextFullPass() async throws {
        try await onReconcilerTime { _, events in
            let truth = Side(entries(4), label: "truth")
            let derived = Side(entries(4), label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            try await reconciler.pass()
            await truth.set("new", 5)   // written, and nobody called changed(_:)
            try await reconciler.pass()
            #expect(await derived.entries["new"] == 5)
            #expect(events.count("reconciler.drift_found") == 1)
        }
    }

    @Test(.failureMode("design/30", "the process crashes in the middle of a pass"))
    func aCrashMidPassLeavesFinishedCorrectionsAndTheNextPassFinishes() async throws {
        try await onReconcilerTime { _, _ in
            let truth = Side(entries(6), label: "truth")
            let derived = Side([:], label: "derived")
            let crashed = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy { $0.concurrency = 1 })
            let handle = TaskHandle()
            let writes = Atomic<Int>(0)
            // The crash: the fourth write is where the process dies.
            await derived.intercept { call in
                guard case .write = call, writes.add(1, ordering: .relaxed).newValue == 4 else { return }
                handle.cancel()
            }
            let task = Task<ReconcilePassReport<String>, any Error> { try await crashed.pass() }
            handle.set(task)
            await #expect(throws: ReconcileError.cancelled) { try await task.value }
            #expect(await derived.entries.count == 3, "the finished corrections stand")
            await derived.intercept(nil)
            let relaunched = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            let report = try await relaunched.pass()
            #expect(report.differences == 3, "it reads both sides and finishes the rest")
            #expect(await derived.entries == entries(6))
        }
    }

    @Test(.failureMode("design/30", "a pass is asked for while one runs"))
    func passesQueueAndNeverCorrectAKeyTwiceAtOnce() async throws {
        try await simulated { _, _ in
            let truth = Side(entries(4), label: "truth")
            let derived = Side([:], label: "derived")
            await derived.slowWrites(by: .seconds(1))
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy())
            async let first = reconciler.pass()
            async let second = reconciler.pass()
            let reports = try await [first, second]
            #expect(await derived.concurrentWrites == 0)
            #expect(reports.map(\.differences).sorted() == [0, 4], "the second ran after the first, from a new reading")
            #expect(await derived.writes.count == 4)
        }
    }

    @Test(.failureMode("design/30", "a caller's deadline passes while it waits for a pass in progress"))
    func aCallerWhoseDeadlinePassesStopsWaitingAndThePassGoesOn() async throws {
        try await simulated { clock, _ in
            let truth = Side(entries(2), label: "truth")
            let derived = Side([:], label: "derived")
            await derived.slowWrites(by: .seconds(8))
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy { $0.concurrency = 1 })
            let (running, impatient) = try await { () async throws -> (ReconcilePassReport<String>, ReconcileError?) in
                async let running = reconciler.pass()
                while await truth.calls == 0 { await Task.yield() }   // it holds the lock
                let waited = clock.now
                let impatient: ReconcileError?
                do throws(ReconcileError) {
                    _ = try await withDeadline(Deadline.after(.seconds(3))) { () async throws(ReconcileError) in
                        try await reconciler.pass()
                    }
                    impatient = nil
                } catch {
                    impatient = error
                }
                #expect(waited.duration(to: clock.now) == .seconds(3), "it waited no longer than its own deadline")
                return (try await running, impatient)
            }()
            #expect(impatient == .cancelled)
            #expect(running.applied == 2, "the pass in progress went on")
        }
    }

    @Test(.failureMode("design/30", "a background job's time runs out during a pass"))
    func anExpiringBackgroundTaskCancelsThePassAndItsFinishedCorrectionsStand() async throws {
        try await onReconcilerTime { _, _ in
            let truth = Side(entries(4), label: "truth")
            let derived = Side([:], label: "derived")
            let reconciler = Reconciler(SideSync(truth: truth, derived: derived), policy: quickPolicy { $0.concurrency = 1 })
            let cause = CancellationCauseBox(parent: nil)
            let handle = TaskHandle()
            let writes = Atomic<Int>(0)
            let seenCause = Mutex<CancellationCause?>(nil)
            await derived.intercept { call in
                guard case .write = call, writes.add(1, ordering: .relaxed).newValue == 2 else { return }
                // What a BackgroundJob does when the system expires its task.
                cause.record(.systemExpiring)
                handle.cancel()
                seenCause.withLock { $0 = CancellationCause.current }
            }
            let job = Task<ReconcilePassReport<String>, any Error> {
                try await CancellationCauseBox.$current.withValueTyped(cause) { () async throws(ReconcileError) -> ReconcilePassReport<String> in
                    try await reconciler.pass()
                }
            }
            handle.set(job)
            await #expect(throws: ReconcileError.cancelled) { try await job.value }
            #expect(seenCause.withLock { $0 } == .systemExpiring, "the correction in flight sees why")
            #expect(await derived.entries.count == 1, "the finished correction stands")
            #expect(reconciler.status.phase == .converging(differences: 4))
        }
    }

    @Test(.failureMode("design/30", "the reconciliation declares a .notRepeatable or .readOnly correction"))
    func aCorrectionThatIsNotRepeatableIsRefusedWhereTheReconcilerIsMade() async {
        await #expect(processExitsWith: .failure) {
            struct Charges: Reconciliation {
                static let name = "test.charges"
                static let readsTruth = Backend.remote("test.charges").readOnly("truth")
                static let readsDerived = Backend.remote("test.charges").readOnly("derived")
                static let corrects = Backend.remote("test.charges").notRepeatable("charge")
                func desired(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Int] { [:] }
                func actual(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Int] { [:] }
                func correct(_ correction: Correction<String, Int, Int>, attempt: Attempt) async throws {}
            }
            _ = Reconciler(Charges())
        }
        await #expect(processExitsWith: .failure) {
            struct Lookups: Reconciliation {
                static let name = "test.lookups"
                static let readsTruth = Backend.remote("test.lookups").readOnly("truth")
                static let readsDerived = Backend.remote("test.lookups").readOnly("derived")
                static let corrects = Backend.remote("test.lookups").readOnly("correct")
                func desired(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Int] { [:] }
                func actual(_ scope: ReconcileScope<String>, attempt: Attempt) async throws -> [String: Int] { [:] }
                func correct(_ correction: Correction<String, Int, Int>, attempt: Attempt) async throws {}
            }
            _ = Reconciler(Lookups())
        }
    }

    // MARK: The plan

    @Test func thePlanAppliedToTheActualReadingGivesTheDesiredOne() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<300 {
            let desired = Self.randomSide(&generator)
            let actual = Self.randomSide(&generator)
            let plan = ReconcilePlan(desired: desired, actual: actual, using: SideSync(truth: Side(label: "t"), derived: Side(label: "d")))
            var result = actual
            for correction in plan.corrections {
                switch correction {
                case .create(let key, let value), .update(let key, let value, was: _): result[key] = value
                case .remove(let key, was: _): result[key] = nil
                }
            }
            #expect(result == desired)
            let kinds = plan.corrections.map(\.kind)
            let firstRemove = kinds.firstIndex(of: .remove) ?? kinds.count
            #expect(kinds[..<firstRemove].allSatisfy { $0 != .remove }, "creates and updates first")
            #expect(kinds[firstRemove...].allSatisfy { $0 == .remove })
            #expect(plan.corrections[..<firstRemove].map(\.key) == plan.corrections[..<firstRemove].map(\.key).sorted())
            #expect(plan.corrections[firstRemove...].map(\.key) == plan.corrections[firstRemove...].map(\.key).sorted())
            #expect(plan.removals == kinds.count - firstRemove)
            #expect(plan.unchanged == desired.count { actual[$0.key] == $0.value })
            let same = ReconcilePlan(desired: desired, actual: desired, using: SideSync(truth: Side(label: "t"), derived: Side(label: "d")))
            #expect(same.corrections.isEmpty)
        }
    }

    static func randomSide(_ generator: inout SeededGenerator) -> [String: Int] {
        var side: [String: Int] = [:]
        for _ in 0..<Int.random(in: 0..<20, using: &generator) {
            side[key(Int.random(in: 0..<30, using: &generator))] = Int.random(in: 0..<3, using: &generator)
        }
        return side
    }

    @Test func theGuardsLimitIsTheLargerOfItsCountAndShare() {
        let guarded = RemovalGuard.atMost(share: 0.10, orCount: 5)
        #expect(guarded.limit(derived: 0) == 5)
        #expect(guarded.limit(derived: 1_000) == 100)
        #expect(guarded.limit(derived: 1_009) == 100, "rounded down")
        #expect(RemovalGuard.unguarded.limit(derived: 10) == nil)
        #expect(ReconcilePolicy().removals == guarded)
    }
}

/// SplitMix64, for the plan's properties.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
