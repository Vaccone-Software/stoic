@testable import Stoic
import StoicTesting
import Testing

@Suite("hedge")
struct HedgeTests {
    enum HedgeError: Error, Equatable {
        case failed(Int)
        case cancelled(Int)
    }

    /// Everything a hedged test observes about its attempts.
    final class Log: Sendable {
        private let state = SendableBox((started: [Int](), running: 0, cancelled: [(attempt: Int, cause: CancellationCause?)](), elapsed: [Int: Duration]()))
        func began(_ attempt: Attempt) {
            state.mutate { $0.started.append(attempt.number); $0.running += 1; $0.elapsed[attempt.number] = attempt.elapsed }
        }
        func ended() { state.mutate { $0.running -= 1 } }
        func wasCancelled(_ attempt: Int) {
            state.mutate { $0.cancelled.append((attempt, CancellationCause.current)) }
        }
        var started: [Int] { state.value.started }
        var running: Int { state.value.running }
        var cancelled: [Int] { state.value.cancelled.map(\.attempt).sorted() }
        var causes: [CancellationCause?] { state.value.cancelled.map(\.cause) }
        func elapsed(_ attempt: Int) -> Duration? { state.value.elapsed[attempt] }
    }

    /// An attempt that sleeps on the clock for `duration` from when it was
    /// started, then returns `value` or throws.
    func nap(
        _ attempt: Attempt, _ duration: Duration, clock: TestClock, log: Log, returning value: String? = nil
    ) async throws(HedgeError) -> String {
        log.began(attempt)
        defer { log.ended() }
        do {
            try await clock.sleep(until: .init(offset: attempt.elapsed + duration), tolerance: nil)
        } catch {
            log.wasCancelled(attempt.number)
            throw .cancelled(attempt.number)
        }
        guard let value else { throw .failed(attempt.number) }
        return value
    }

    func runHedge(
        clock: TestClock, events: RecordingInstrumentation, delay: Duration = .milliseconds(100), maxAttempts: Int = 2,
        budget: RetryBudget = .perCallSite,
        operation: @escaping @concurrent @Sendable (Attempt) async throws(HedgeError) -> String
    ) -> Task<Result<String, HedgeError>, Never> {
        Task {
            await withTestAmbient(clock: clock, events: events) {
                do throws(HedgeError) {
                    return .success(try await hedge(.idempotent, after: delay, maxAttempts: maxAttempts, budget: budget, label: "test", operation: operation))
                } catch {
                    return .failure(error)
                }
            }
        }
    }

    @Test(.failureMode("design/10", "the first hedged attempt finishes before delay")) func aFastFirstAttemptNeverHedgesAndLeavesNoTimerBehind() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let task = runHedge(clock: clock, events: events) { attempt in
            log.began(attempt)
            defer { log.ended() }
            return "fast"
        }
        #expect(await task.value == .success("fast"))
        #expect(log.started == [1])
        #expect(clock.sleeperCount == 0)
        #expect(events.names.isEmpty)
    }

    @Test(.failureMode("design/10", "the winner is found"), .failureMode("design/10", "the first attempt is slow")) func aSlowFirstAttemptIsHedgedAndTheLoserIsCancelledAndAwaited() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let task = runHedge(clock: clock, events: events) { attempt throws(HedgeError) in
            // The first attempt is slow; the hedge is quick.
            try await self.nap(attempt, attempt.number == 1 ? .seconds(10) : .milliseconds(30), clock: clock, log: log, returning: "attempt \(attempt.number)")
        }
        await clock.waitForSleepers(count: 2)   // attempt 1 and the hedge timer
        await clock.advance(by: .milliseconds(100))
        await clock.waitForSleepers(count: 2)   // attempts 1 and 2
        await clock.advance(by: .milliseconds(30))
        #expect(await task.value == .success("attempt 2"))
        // Hedge's own timing: attempt 2 starts at 100 ms and needs 30 ms.
        #expect(log.started == [1, 2] || log.started == [2, 1])
        #expect(log.elapsed(2) == .milliseconds(100))
        // Awaited: by the time hedge returned, the loser had finished.
        #expect(log.running == 0)
        #expect(log.cancelled == [1])
        #expect(log.causes == [.superseded])
        #expect(clock.sleeperCount == 0)
        let started = events.events(named: "hedge.started")
        #expect(started.count == 1)
        #expect(started[0].number("attempt") == 2)
        #expect(started[0].duration("elapsed") == .milliseconds(100))
        #expect(started[0].label == "test")
        let won = events.events(named: "hedge.won")
        #expect(won.count == 1)
        #expect(won[0].number("attempt") == 2)
        #expect(won[0].number("started") == 2)
    }

    @Test func theOriginalAttemptCanStillWinAfterAHedgeStarts() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let task = runHedge(clock: clock, events: events) { attempt throws(HedgeError) in
            try await self.nap(attempt, attempt.number == 1 ? .milliseconds(150) : .seconds(10), clock: clock, log: log, returning: "attempt \(attempt.number)")
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .milliseconds(100))   // the hedge starts
        await clock.waitForSleepers(count: 2)         // attempt 1 and 2 (no third: maxAttempts is 2)
        await clock.advance(by: .milliseconds(50))    // attempt 1 finishes
        #expect(await task.value == .success("attempt 1"))
        #expect(log.cancelled == [2])
        #expect(log.running == 0)
        #expect(events.events(named: "hedge.won")[0].number("attempt") == 1)
    }

    @Test func aLoserThatIgnoresCancellationIsWaitedFor() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let gate = AsyncGate()
        let returned = SendableBox(false)
        let loserCancelled = SendableBox(false)
        let task = Task {
            let result = await withTestAmbient(clock: clock, events: events) { () async -> String? in
                do throws(HedgeError) {
                    return try await hedge(.idempotent, after: .milliseconds(100)) { attempt throws(HedgeError) in
                        if attempt.number == 1 {
                            // Cannot be cancelled, but can see that it was.
                            await withTaskCancellationHandler {
                                await gate.wait()
                            } onCancel: {
                                loserCancelled.mutate { $0 = true }
                            }
                            return "slow"
                        }
                        return "hedge"
                    }
                } catch {
                    return nil
                }
            }
            returned.mutate { $0 = true }
            return result
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(100))
        await waitUntil { loserCancelled.value }   // the hedge has a winner and has cancelled the loser
        #expect(await holdsThroughout { !returned.value })   // but the loser is still running, so hedge has not returned
        gate.open()
        #expect(await task.value == "hedge")
        #expect(returned.value)
    }

    @Test(.failureMode("design/10", "the hedge budget has no token"), .failureMode("design/03", "the hedge budget is empty")) func anEmptyBudgetPreventsHedgingAndTheFirstAttemptCarriesOn() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let empty = RetryBudget(ratio: 0, reservePerSecond: 0, reserveCapacity: 0)
        let task = runHedge(clock: clock, events: events, budget: empty) { attempt throws(HedgeError) in
            try await self.nap(attempt, .milliseconds(500), clock: clock, log: log, returning: "only")
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .milliseconds(100))
        await clock.waitForSleepers(count: 1)
        #expect(log.started == [1])
        await clock.advance(by: .milliseconds(400))
        #expect(await task.value == .success("only"))
        #expect(log.started == [1])
        #expect(events.names == ["hedge.budget_exhausted"])
        #expect(events.events(named: "hedge.budget_exhausted")[0].level == .warning)
    }

    @Test func eachHedgeSpendsATokenSoABudgetOfOneAllowsOne() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let budget = RetryBudget(ratio: 0, reservePerSecond: 0, reserveCapacity: 1)
        for expectedHedge in [true, false] {
            let before = log.started.count
            let task = runHedge(clock: clock, events: events, budget: budget) { attempt throws(HedgeError) in
                try await self.nap(attempt, attempt.number == 1 ? .seconds(5) : .milliseconds(10), clock: clock, log: log, returning: "done")
            }
            await clock.waitForSleepers(count: 2)
            await clock.advance(by: .milliseconds(100))
            if expectedHedge {
                await clock.waitForSleepers(count: 2)
                await clock.advance(by: .milliseconds(10))
                #expect(await task.value == .success("done"))
                #expect(log.started.count - before == 2)
            } else {
                await clock.waitForSleepers(count: 1)
                await clock.advance(by: .seconds(5))
                #expect(await task.value == .success("done"))
                #expect(log.started.count - before == 1)
            }
        }
    }

    @Test(.failureMode("design/10", "every attempt fails")) func ifEveryAttemptFailsTheFirstFailureInCompletionOrderIsThrown() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let task = runHedge(clock: clock, events: events) { attempt throws(HedgeError) in
            // Attempt 1 fails at 500 ms; attempt 2 starts at 100 ms and fails at 200 ms.
            try await self.nap(attempt, attempt.number == 1 ? .milliseconds(500) : .milliseconds(100), clock: clock, log: log)
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .milliseconds(100))
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .milliseconds(100))   // attempt 2 fails; attempt 1 still runs
        await waitUntil { events.events(named: "hedge.attempt_failed").count == 1 }   // hedge has consumed it
        #expect(log.running == 1)
        await clock.advance(by: .milliseconds(300))
        #expect(await task.value == .failure(.failed(2)))
        #expect(events.events(named: "hedge.all_failed").count == 1)
        #expect(events.events(named: "hedge.all_failed")[0].number("attempts") == 2)
    }

    @Test(.failureMode("design/10", "an attempt fails and none is running")) func aFailureWithNothingElseRunningEndsTheHedgeAtOnce() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let task = runHedge(clock: clock, events: events) { attempt throws(HedgeError) in
            try await self.nap(attempt, .milliseconds(40), clock: clock, log: log)
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .milliseconds(40))   // fails before the hedge delay
        #expect(await task.value == .failure(.failed(1)))
        #expect(log.started == [1])               // failure is retry's business
        #expect(clock.sleeperCount == 0)          // and the hedge timer was cancelled
        #expect(events.names == ["hedge.attempt_failed", "hedge.all_failed"])
    }

    @Test(.failureMode("design/10", "maxAttempts attempts have started")) func noMoreAttemptsStartThanMaxAttemptsAndEachWaitsItsOwnDelay() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let task = runHedge(clock: clock, events: events, maxAttempts: 3) { attempt throws(HedgeError) in
            try await self.nap(attempt, .seconds(10), clock: clock, log: log, returning: "attempt \(attempt.number)")
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .milliseconds(100))
        await clock.waitForSleepers(count: 3)          // two attempts and the next timer
        #expect(log.started.sorted() == [1, 2])
        await clock.advance(by: .milliseconds(100))
        await clock.waitForSleepers(count: 3)          // three attempts, no timer
        #expect(log.started.sorted() == [1, 2, 3])
        #expect(log.elapsed(3) == .milliseconds(200))
        await clock.advance(by: .seconds(5))           // far past any further delay
        #expect(log.started.count == 3)
        await clock.advance(to: .init(offset: .seconds(10)))   // attempt 1 is due; 2 and 3 are not
        #expect(await task.value == .success("attempt 1"))
        #expect(log.cancelled == [2, 3])
    }

    @Test(.failureMode("design/10", "the caller is cancelled")) func aCallerCancelledMidHedgeCancelsEveryAttemptAndWaitsForThem() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let task = runHedge(clock: clock, events: events, maxAttempts: 3) { attempt throws(HedgeError) in
            try await self.nap(attempt, .seconds(10), clock: clock, log: log, returning: "never")
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .milliseconds(100))
        await clock.waitForSleepers(count: 3)
        task.cancel()
        let result = await task.value
        #expect(result == .failure(.cancelled(1)) || result == .failure(.cancelled(2)))
        #expect(log.running == 0)
        #expect(log.cancelled == [1, 2])
        #expect(clock.sleeperCount == 0)
    }

    @Test(.failureMode("design/10", "the deadline has passed when a hedge is due")) func noHedgeStartsOnceTheDeadlineHasPassed() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let task = Task {
            await withTestAmbient(clock: clock, events: events) {
                await Deadline.$stored.withValue(.after(.milliseconds(50))) { () async -> Result<String, HedgeError> in
                    do throws(HedgeError) {
                        return .success(try await hedge(.idempotent, after: .milliseconds(100)) { attempt throws(HedgeError) in
                            try await self.nap(attempt, .milliseconds(300), clock: clock, log: log, returning: "only")
                        })
                    } catch {
                        return .failure(error)
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .milliseconds(100))   // the deadline passed at 50 ms
        await clock.waitForSleepers(count: 1)
        #expect(log.started == [1])
        await clock.advance(by: .milliseconds(200))
        #expect(await task.value == .success("only"))
        #expect(events.names == ["hedge.deadline_skip"])
    }

    @Test func aSingleAttemptJustRunsTheOperation() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let log = Log()
        let task = runHedge(clock: clock, events: events, maxAttempts: 1) { attempt throws(HedgeError) in
            try await self.nap(attempt, .seconds(1), clock: clock, log: log, returning: "once")
        }
        await clock.waitForSleepers(count: 1)
        #expect(clock.sleeperCount == 1)   // no hedge timer
        await clock.advance(by: .seconds(1))
        #expect(await task.value == .success("once"))
    }

    // MARK: - Model

    @Test func theWinnerAndTheFailureMatchAModelOverRandomTimelines() async {
        for seed in 1...60 as ClosedRange<UInt64> {
            var generator = RandomSource.seeded(seed).generator()
            let maxAttempts = Int.random(in: 2...5, using: &generator)
            let delay = 100
            // Distinct end times that never coincide with a tick or each other.
            var ends: Set<Int> = []
            var plan: [(duration: Int, succeeds: Bool)] = []
            for index in 0..<maxAttempts {
                var duration: Int
                repeat {
                    duration = Int.random(in: 1...899, using: &generator)
                } while duration % delay == 0 || ends.contains(index * delay + duration) || (index * delay + duration) % delay == 0
                ends.insert(index * delay + duration)
                plan.append((duration, Int.random(in: 0..<3, using: &generator) == 0))
            }

            // The model: events in time order, tracking what runs.
            enum Kind { case tick(Int), end(Int) }
            var timeline: [(time: Int, kind: Kind)] = []
            for index in 1..<maxAttempts { timeline.append((index * delay, .tick(index))) }
            for (index, attempt) in plan.enumerated() { timeline.append((index * delay + attempt.duration, .end(index))) }
            timeline.sort { $0.time < $1.time }
            var started = 1
            var running: Set<Int> = [0]
            var timerPending = true
            var winner: Int?
            var firstFailure: Int?
            var steps: [(time: Int, sleepersBefore: Int, failsHere: Bool)] = []
            var finished = false
            for event in timeline where !finished {
                if case .tick(let index) = event.kind {
                    guard timerPending, index == started else { continue }
                }
                if case .end(let index) = event.kind, !running.contains(index) { continue }
                var failsHere = false
                if case .end(let index) = event.kind { failsHere = !plan[index].succeeds }
                steps.append((event.time, running.count + (timerPending ? 1 : 0), failsHere))
                switch event.kind {
                case .tick(let index):
                    running.insert(index)
                    started += 1
                    timerPending = started < maxAttempts
                case .end(let index):
                    running.remove(index)
                    if plan[index].succeeds {
                        winner = index
                        finished = true
                    } else {
                        if firstFailure == nil { firstFailure = index }
                        if running.isEmpty { finished = true }
                    }
                }
            }

            let clock = TestClock()
            let events = RecordingInstrumentation()
            let log = Log()
            let captured = plan
            let task = runHedge(clock: clock, events: events, maxAttempts: maxAttempts) { attempt throws(HedgeError) in
                let step = captured[attempt.number - 1]
                return try await self.nap(attempt, .milliseconds(step.duration), clock: clock, log: log, returning: step.succeeds ? "attempt \(attempt.number)" : nil)
            }
            var failuresConsumed = 0
            for step in steps {
                await clock.waitForSleepers(count: step.sleepersBefore)
                await clock.advance(to: .init(offset: .milliseconds(step.time)))
                if step.failsHere {
                    // Completion order is the order the hedge consumes results in,
                    // so let it consume this failure before time moves again.
                    failuresConsumed += 1
                    await waitUntil("seed \(seed): failure \(failuresConsumed) never consumed") {
                        events.events(named: "hedge.attempt_failed").count == failuresConsumed
                    }
                }
            }
            let result = await task.value
            if let winner {
                #expect(result == .success("attempt \(winner + 1)"), "seed \(seed)")
            } else if let firstFailure {
                #expect(result == .failure(.failed(firstFailure + 1)), "seed \(seed)")
            }
            #expect(log.running == 0, "seed \(seed)")
            #expect(log.started.count == started, "seed \(seed)")
            #expect(clock.sleeperCount == 0, "seed \(seed)")
        }
    }
}
