@testable import Stoic
import StoicTesting
import Testing

// Failure-mode table rows (design/03, 04, 07, 08, 09) that no test covered.

@Suite("Failure modes: concurrency")
struct ConcurrencyFailureModeTests {
    struct Crash: Error {}

    /// "mapConcurrent caller is cancelled: all children cancelled and
    /// awaited; CancellationError propagates."
    @Test(.timeLimit(.minutes(1)), .failureMode("design/03", "mapConcurrent caller is cancelled"))
    func aCancelledMapConcurrentCancelsAndAwaitsItsChildrenAndThrowsCancellation() async {
        let started = SendableBox(0)
        let running = SendableBox(0)
        let ready = TestGate()
        let caller = Task {
            try await mapConcurrent(Array(0..<1_000), limit: 4) { (_: Int) async throws(CancellationError) -> Int in
                running.mutate { $0 += 1 }
                defer { running.mutate { $0 -= 1 } }
                if started.mutate({ $0 += 1; return $0 }) == 4 { ready.open() }
                do { try await Task.sleep(for: .seconds(3600)) } catch { throw CancellationError() }
                return 0
            }
        }
        await ready.wait()
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(running.value == 0, "the call returned while a transform was still running")
        #expect(started.value == 4, "no element starts after the caller was cancelled")
    }

    /// The part of the same row for work that ignores cancellation. A
    /// transform that cannot throw cannot report the cancellation, but the
    /// pool must still stop taking new elements (review finding 13: today it
    /// starts all of them). Another change is revising this behaviour, so the
    /// expectation is a known issue that may start passing.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledMapConcurrentOverCancellationIgnoringWorkStartsNothingNew() async {
        let started = SendableBox(0)
        let release = TestGate()
        let ready = TestGate()
        let caller = Task {
            await mapConcurrentResults(Array(0..<200), limit: 4) { (value: Int) async throws(Crash) -> Int in
                if started.mutate({ $0 += 1; return $0 }) == 4 { ready.open() }
                await release.wait()   // ignores cancellation
                return value
            }
        }
        await ready.wait()
        caller.cancel()
        release.open()
        _ = await caller.value
        #expect(started.value == 4, "\(started.value) of 200 elements started for a cancelled caller")
    }

    /// "a TaskSlot task ignores cancellation forever: next run does not wait
    /// for it; it stays accounted for, and its late answer is dropped."
    @Test(.stoic(seed: 7), .timeLimit(.minutes(1)),
          .failureMode("design/03", "a TaskSlot task ignores cancellation forever"),
          .failureMode("design/03", "a superseded TaskSlot task finishes after the new one"))
    func workThatIgnoresCancellationForeverDoesNotBlockTheNextRun() async {
        let slot = TaskSlot<String, Never>(label: "stubborn")
        let forever = TestGate()
        let started = TestGate()
        let delivered = SendableBox<[String]>([])
        slot.run {
            started.open()
            await forever.wait()
            return "old"
        } deliver: { result in delivered.mutate { $0.append(result.get()) } }
        await started.wait()
        slot.run { "fresh" } deliver: { result in delivered.mutate { $0.append(result.get()) } }

        #expect(await eventually { delivered.value == ["fresh"] }, "the next run waited for the stubborn one")
        #expect(slot.unfinishedCount == 1, "the straggler stays accounted for")
        let tag = Ambient.current.ledgerTag!
        #expect(TaskLedger.entries(tag: tag).map(\.label) == ["stubborn"], "and visible in the task ledger")

        // When it finally returns, its answer is dropped and reported.
        forever.open()
        #expect(await eventually { StoicTest.events.names.contains("slot.superseded_late") })
        await slot.cancelAndWait()
        #expect(delivered.value == ["fresh"])
        #expect(slot.unfinishedCount == 0)
    }
}

@Suite("Failure modes: scope exit")
struct ScopeExitFailureModeTests {
    enum Failure: Error { case boom }

    /// "the enclosing deadline has already passed at exit: finalizers still
    /// get exitDeadlineFloor each." The exit budget has ten seconds left, so
    /// it is the passed deadline alone that leaves only the floor: 250 ms.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/04", "the enclosing deadline has already passed at exit"))
    func finalizersStillGetTheFloorWhenTheEnclosingDeadlineHasPassed() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = OrderLog()
        let task = Task {
            await withAmbient({ $0.clock = clock.erased; $0.instrumentation = events }) {
                await withTimeout(.seconds(1)) {
                    await withScope(exitBudget: .seconds(10)) { scope in
                        scope.onExit(label: "needs 200ms") { _ in
                            try await clock.sleep(for: .milliseconds(200))
                            log.append("200ms done")
                        }
                        scope.onExit(label: "needs 300ms") { _ in
                            try await clock.sleep(for: .milliseconds(300))
                            log.append("300ms done")
                        }
                        // Ended by the deadline.
                        try? await Task.sleep(for: .seconds(3600))
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))   // the deadline passes; the scope exits

        // The newest finalizer (300 ms) is timed with the 250 ms floor and abandoned...
        let first = await eventually { clock.pendingDeadlines.map(\.offset) == [.milliseconds(1250), .milliseconds(1300)] }
        #expect(first, "\(clock.pendingDeadlines)")
        await clock.advance(to: clock.now.advanced(by: .milliseconds(250)))
        // ...and the next, which needs 200 ms, still gets its own floor and finishes.
        let second = await eventually { clock.pendingDeadlines.map(\.offset) == [.milliseconds(1450), .milliseconds(1500)] }
        #expect(second, "\(clock.pendingDeadlines)")
        await clock.advance(to: clock.now.advanced(by: .milliseconds(200)))
        await task.value

        #expect(log.values == ["200ms done"])
        #expect(events.names.filter { $0 == "scope.finalizer_abandoned" }.count == 1)
        #expect(!events.names.contains("scope.finalizer_failed"))
    }

    /// design/04 says an abandoned finalizer is abandoned "via the ledger"
    /// and principle 3 says abandonment is counted. Review finding 12: the
    /// finalizer task is in neither the TaskLedger nor AbandonedWork.
    @Test(.stoic(seed: 8), .timeLimit(.minutes(1)))
    func anAbandonedFinalizerIsAccountedFor() async {
        let clock = TestClock()
        let hung = TestGate()
        let task = Task {
            await withAmbient({ $0.clock = clock.erased }) {
                await withScope(label: "ledger-test") { scope in
                    scope.onExit(label: "wedged") { _ in await hung.wait() }
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advanceToNextDeadline()
        await task.value

        let tag = Ambient.current.ledgerTag!
        let tracked = TaskLedger.entries(tag: tag).count + AbandonedWork.current.filter { $0.label.contains("ledger-test") }.count
        #expect(tracked >= 1, "the hung finalizer is invisible to diagnostics")
        hung.open()
    }

    /// Cleanup keeps its own time. The deadline that ended the body has
    /// passed; a finalizer that inherited it would have every Stoic call it
    /// makes refused, or run already cancelled.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/04", "a finalizer calls a Stoic primitive after the deadline that ended the scope"))
    func aFinalizerAfterTheDeadlineRunsUnderItsOwnAllowance() async {
        let clock = TestClock()
        let observed = SendableBox<[String]>([])
        let task = Task {
            await withTestAmbient(clock: clock) {
                await withTimeout(.seconds(1)) {
                    await withScope { scope in
                        scope.onExit(label: "flush") { _ in
                            let left = Deadline.current.map { clock.erased.now.duration(to: $0.instant) }
                            observed.mutate { $0.append("deadline in \(left.map { "\($0)" } ?? "none")") }
                            let cancelled = await withTimeout(.seconds(2)) { () async -> Bool in Task.isCancelled }
                            observed.mutate { $0.append("timeout cancelled on entry: \(cancelled)") }
                            do {
                                try await Bulkhead(maxConcurrent: 1, label: "flush").execute { () async throws(Failure) in }
                                observed.mutate { $0.append("bulkhead ran") }
                            } catch {
                                observed.mutate { $0.append("bulkhead: \(error)") }
                            }
                        }
                        try? await Ambient.sleep(for: .seconds(3600))
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(1))
        await task.value
        // The enclosing deadline has passed, so the finalizer's allowance is the floor.
        #expect(observed.value == ["deadline in \(ScopeState.exitDeadlineFloor)", "timeout cancelled on entry: false", "bulkhead ran"])
    }

    /// The same for a saga: the refund that undoes a charge is not refused
    /// because the deadline that ended the saga has passed.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/04", "a finalizer calls a Stoic primitive after the deadline that ended the scope"))
    func aCompensationAfterTheDeadlineIsNotRefused() async {
        let clock = TestClock()
        let refund = SendableBox<String?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) {
                    try await withSaga { saga in
                        _ = try await saga.step(label: "charge") { () async throws -> Int in 42 } compensate: { _ in
                            do {
                                try await Bulkhead(maxConcurrent: 1, label: "payments").execute { () async throws(Failure) in }
                                refund.mutate { $0 = "refunded" }
                            } catch {
                                refund.mutate { $0 = "refused: \(error)" }
                            }
                        }
                        try await Ambient.sleep(for: .seconds(3600))   // shipping hangs; the deadline ends the saga
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(1))
        _ = try? await task.value
        #expect(refund.value == "refunded")
    }

    /// A deadline with time left bounds the exit, as the exit budget does:
    /// a scope inside a two-second timeout does not take ten seconds more.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/04", "the enclosing deadline has time left at exit"))
    func theEnclosingDeadlineBoundsEachFinalizer() async {
        let clock = TestClock()
        let task = Task {
            await withTestAmbient(clock: clock) {
                await withTimeout(.seconds(2)) {
                    await withScope(exitBudget: .seconds(10), finalizerTimeout: .seconds(5)) { scope in
                        scope.onExit(label: "slow close") { _ in await AsyncGate().wait() }
                        try? await Ambient.sleep(for: .seconds(1))
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)   // the timeout and the body
        await clock.advance(by: .seconds(1))
        await clock.waitForSleepers(count: 2)   // the timeout and the finalizer's timer
        // One second of the deadline is left: the finalizer gets that, not its five.
        #expect(clock.pendingDeadlines.map(\.offset) == [.seconds(2), .seconds(2)])
        await clock.advance(by: .seconds(1))
        await task.value
    }

    /// Waiting for forks is part of the exit and charged to its budget: a
    /// fork that uses it up leaves the finalizers only the floor.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/04", "waiting for forks uses up the exit budget"))
    func waitingForForksIsChargedToTheExitBudget() async throws {
        let clock = TestClock()
        let stubborn = AsyncGate()
        defer { stubborn.open() }
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTaskScope(exitBudget: .seconds(1), forkTimeout: .seconds(5)) { scope in
                    scope.onExit(label: "close") { _ in await AsyncGate().wait() }
                    scope.fork(label: "stubborn") { await stubborn.wait() }
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        // The fork gets the budget's second, not its five.
        #expect(clock.pendingDeadlines.map(\.offset) == [.seconds(1)])
        await clock.advance(by: .seconds(1))
        await clock.waitForSleepers(count: 1)
        // The budget is spent: the finalizer gets the floor.
        #expect(clock.pendingDeadlines.map(\.offset) == [.seconds(1) + ScopeState.exitDeadlineFloor])
        await clock.advance(by: ScopeState.exitDeadlineFloor)
        try await task.value
    }

    /// The fork wait is not shortened by a passed deadline, as a finalizer's
    /// allowance is: that would abandon, still running, every fork whose
    /// cooperative stop takes longer than the floor.
    @Test(.timeLimit(.minutes(1))) func aPassedDeadlineDoesNotShortenTheForkWait() async throws {
        let clock = TestClock()
        let stubborn = AsyncGate()
        defer { stubborn.open() }
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) {
                    try await withTaskScope(forkTimeout: .seconds(5)) { scope in
                        scope.fork(label: "winding down") { await stubborn.wait() }
                        try? await Ambient.sleep(for: .seconds(3600))
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)   // the timeout and the body
        await clock.advance(by: .seconds(1))
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines.map(\.offset) == [.seconds(6)])
        await clock.advance(by: .seconds(5))
        _ = try? await task.value
    }

    /// A hung finalizer is abandoned, and counted while it runs: the release
    /// behind it of what it may still be using is quarantined, not closed
    /// under it. It reads the deadline as its cause.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/04", "a finalizer hangs"))
    func anAbandonedFinalizerQuarantinesTheReleasesBehindIt() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let hung = AsyncGate()
        let log = OrderLog()
        let cause = SendableBox<CancellationCause?>(nil)
        let task = Task {
            await withTestAmbient(clock: clock, events: events) {
                await withScope { scope in
                    scope.onExit(label: "close session", ifWorkAbandoned: .quarantine) { _ in log.append("session closed") }
                    scope.onExit(label: "close stream") { _ in log.append("stream closed") }
                    scope.onExit(label: "drain stream on session", timeout: .milliseconds(100)) { _ in
                        await hung.wait()
                        cause.mutate { $0 = CancellationCause.current }
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(100))
        await task.value
        #expect(log.values == ["stream closed"])
        #expect(events.events(named: "scope.release_quarantined").first?.fields.contains { $0.key == "finalizer" && "\($0.value)" == "close session" } == true)
        hung.open()
        #expect(await eventually { cause.value != nil })
        #expect(cause.value == .deadline)
    }

    /// A saga's compensation that overruns is abandoned and the chain goes
    /// on, but out of order: each compensation that starts while it still
    /// runs is reported.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/04", "a saga's compensation overruns"))
    func aCompensationThatOverrunsIsReportedForEachOneThatOverlapsIt() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let hung = AsyncGate()
        defer { hung.open() }
        let log = OrderLog()
        let task = Task {
            await withTestAmbient(clock: clock, events: events) {
                _ = try? await withSaga(label: "order") { saga in
                    _ = await saga.step(label: "create order") { 1 } compensate: { _ in log.append("order cancelled") }
                    _ = await saga.step(label: "reserve stock") { 2 } compensate: { _ in log.append("stock released") }
                    _ = await saga.step(label: "charge", timeout: .milliseconds(100)) { 3 } compensate: { _ in await hung.wait() }
                    throw Failure.boom
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(100))
        await task.value
        #expect(log.values == ["stock released", "order cancelled"], "the chain is not held up")
        #expect(events.names.contains("scope.finalizer_abandoned"))
        let overlaps = events.events(named: "saga.compensation_overlapped")
        #expect(overlaps.map { $0.level } == [.warning, .warning])
        #expect(overlaps.map(\.label) == ["order", "order"])
        func field(_ event: Event, _ key: String) -> String? { event.fields.first { $0.key == key }.map { "\($0.value)" } }
        #expect(overlaps.map { field($0, "finalizer") } == ["reserve stock", "create order"])
        #expect(overlaps.map { field($0, "still_running") } == ["charge", "charge"])
    }
}

@Suite("Failure modes: services")
struct ServiceFailureModeTests {
    static let database = ServiceKey<Int>("database")
    static let cache = ServiceKey<Int>("cache")
    static let late = ServiceKey<Int>("late")

    /// "the app's task is cancelled" during the start phase: the caller sees
    /// cancellation (not a start failure), what finished starting is stopped
    /// (newest first, with Exit.cancelled), and what never finished is not.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/08", "the app's task is cancelled"))
    func cancellingWhileServicesStartStopsWhatStartedAndReportsCancellation() async {
        let log = OrderLog()
        let cacheEntered = TestGate()
        let lateEntered = TestGate()
        let lateMayFinish = TestGate()
        let graph = try! ServiceGraph(label: "app") {
            Provide(Self.database) { _ in
                log.append("start database")
                return 1
            } stop: { _, exit in log.append("stop database \(exit)") }
            Provide(Self.cache, needs: [Self.database.any]) { _ in
                cacheEntered.open()
                try await Task.sleep(for: .seconds(3600))   // cancellable: never finishes starting
                return 2
            } stop: { _, _ in log.append("stop cache (it never started)") }
            Provide(Self.late) { _ in
                lateEntered.open()
                await lateMayFinish.wait()   // ignores cancellation: finishes after it
                log.append("late started")
                return 3
            } stop: { _, exit in log.append("stop late \(exit)") }
        }
        let task = Task { try await graph.run { _ in log.append("body ran") } }
        await cacheEntered.wait()
        await lateEntered.wait()
        task.cancel()
        lateMayFinish.open()

        do {
            try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("cancellation must not be reported as \(error)")
        }
        #expect(log.values == ["start database", "late started", "stop late cancelled", "stop database cancelled"])
    }
}

@Suite("Failure modes: supervision and state")
struct SupervisionFailureModeTests {
    struct Crash: Error {}

    final class Script: Sendable {
        let starts = SendableBox(0)
        func next() -> Int { starts.mutate { $0 += 1; return $0 } }
    }

    /// "a child ran long then failed: backoff restarts" (resetAfter).
    @Test(.timeLimit(.minutes(1)), .failureMode("design/09", "a child ran long and then failed"), arguments: [
        (resetAfter: Duration.seconds(20), thirdDelay: Duration.seconds(1)),     // ran 25 s: starts over
        (resetAfter: Duration.seconds(3600), thirdDelay: Duration.seconds(4)),   // control: the backoff keeps growing
    ])
    func aChildThatRanLongStartsItsBackoffOver(resetAfter: Duration, thirdDelay: Duration) async {
        let clock = TestClock()
        let script = Script()
        let supervisor = Supervisor(
            label: "reset",
            intensity: .init(maxRestarts: 100, within: .seconds(100_000)),
            backoff: Schedule.exponential(base: .seconds(1)).unjittered(),
            resetAfter: resetAfter
        ) {
            Child("worker") { _ in
                switch script.next() {
                case 1: throw Crash()                                        // t = 0: fails at once
                case 2: try await Ambient.sleep(for: .seconds(5)); throw Crash()    // a short run
                case 3: try await Ambient.sleep(for: .seconds(25)); throw Crash()   // a long run
                default: try await Ambient.sleep(for: .seconds(100_000))
                }
            }
        }
        let run = Task { try await withTestAmbient(clock: clock) { try await supervisor.run() } }

        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines.first?.offset == .seconds(1), "first restart waits the base delay")
        await clock.advance(by: .seconds(1))                                 // t = 1: run 2 starts
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(5))                                 // t = 6: run 2 fails
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines.first?.offset == .seconds(6 + 2), "a short run does not reset: the delay doubles")
        await clock.advance(by: .seconds(2))                                 // t = 8: run 3 starts
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(25))                                // t = 33: run 3 fails
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines.first?.offset == .seconds(33) + thirdDelay, "after \(resetAfter) of running")

        run.cancel()
        _ = try? await run.value
    }

    /// "the Mac sleeps": heartbeats are measured on the liveness clock, which
    /// stops while the machine sleeps; the wall clock keeps going.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/09", "the Mac sleeps"), arguments: [false, true])
    func aHeartbeatDoesNotFireWhileTheLivenessClockStandsStill(machineSleeps: Bool) async {
        let wall = TestClock()
        let liveness = machineSleeps ? TestClock() : wall
        let script = Script()
        let events = RecordingInstrumentation()
        let supervisor = Supervisor(label: "tap", backoff: .immediate) {
            Child("tap", heartbeat: .init(interval: .seconds(5), misses: 2, grace: .seconds(10))) { _ in
                _ = script.next()
                try await Task.sleep(for: .seconds(3600))   // never beats
            }
        }
        let run = Task {
            await withTestAmbient(clock: wall, events: events) {
                await withAmbient({ $0.livenessClock = liveness.erased }) {
                    try? await supervisor.run()
                }
            }
        }

        #expect(await eventually { script.starts.value == 1 })
        // 20 s of wall time pass: the grace period and two silent intervals.
        for seconds in [10, 5, 5] {
            await liveness.waitForSleepers(count: 1)
            await wall.advance(by: .seconds(seconds))
        }
        #expect(wall.now.offset == .seconds(20), "wall time passed")

        if machineSleeps {
            // The control below shows the same wall time is enough to hang
            // a child on one clock; here the liveness clock never moved.
            #expect(liveness.now.offset == .zero)
            #expect(script.starts.value == 1)
            #expect(!events.names.contains("supervisor.child_hung"), "a process that was asleep was not hung")
            // The machine wakes; liveness time passes, and now it is hung.
            for seconds in [10, 5, 5] {
                await liveness.waitForSleepers(count: 1)
                await liveness.advance(by: .seconds(seconds))
            }
        }
        #expect(await eventually { script.starts.value >= 2 })
        #expect(events.names.contains("supervisor.child_hung"))
        run.cancel()
        await run.value
    }

    enum Mode: Sendable, Hashable { case off, on }
    enum Flip: Sendable { case toggle }

    /// "the machine is deallocated: observers finish", and its running state
    /// work is cancelled.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/07", "the machine is deallocated"))
    func deallocatingAStateMachineFinishesItsObserversAndCancelsItsWork() async {
        let seen = SendableBox<[Mode]>([])
        let observerFinished = TestGate()
        let workCancelled = TestGate()
        let workStarted = TestGate()
        var machine: StateMachine<Mode, Flip>? = StateMachine(initial: .off, label: "ephemeral", clock: TestClock().erased) { mode, _ in
            .to(mode == .off ? .on : .off)
        }
        machine!.whileIn(.on, label: "work") { _ in
            workStarted.open()
            do { try await Task.sleep(for: .seconds(3600)) } catch { workCancelled.open() }
        }
        let stream = machine!.states()
        let observer = Task {
            for await mode in stream { seen.mutate { $0.append(mode) } }
            observerFinished.open()
        }
        machine!.send(.toggle)
        await workStarted.wait()
        #expect(await eventually { seen.value.last == .on })

        machine = nil
        await observerFinished.wait()
        await workCancelled.wait()
        await observer.value
        // (The stream keeps only the newest state, so the observer may not
        // have seen .off, but it saw where the machine ended.)
        #expect(seen.value.last == .on)
    }
}
