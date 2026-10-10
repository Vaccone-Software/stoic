@testable import Stoic
import StoicTesting
import Synchronization
import Testing

@Suite("RateLimiter")
struct RateLimiterTests {
    enum Failure: Error, Equatable { case boom }

    /// Starts a task that waits for `permits` and logs when it was served.
    func waiter(
        _ name: String, permits: Int = 1, limiter: RateLimiter, clock: TestClock, log: SendableBox<[String]>
    ) -> Task<Rejection?, Never> {
        Task {
            do throws(Rejection) {
                try await limiter.acquire(permits: permits)
                log.mutate { $0.append("\(name)@\(clock.now.offset)") }
                return nil
            } catch {
                return error
            }
        }
    }

    // MARK: - The bucket

    @Test func aBurstIsAllowedThenTheSteadyRate() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 10, per: .seconds(1), burst: 5, label: "burst", clock: clock.erased)
        #expect(limiter.availablePermits == 5)
        for _ in 0..<5 { #expect(limiter.tryAcquire()) }
        #expect(!limiter.tryAcquire())
        await clock.advance(by: .milliseconds(99))
        #expect(!limiter.tryAcquire())
        await clock.advance(by: .milliseconds(1))
        #expect(limiter.tryAcquire())
        #expect(!limiter.tryAcquire())
        await clock.advance(by: .seconds(10))   // far more than a full bucket
        #expect(limiter.availablePermits == 5)
    }

    @Test func refillIsExactEvenWhenTheIntervalDoesNotDivide() async {
        // Three permits per second: a permit every 333,333,333.33… ns. Over
        // ten seconds of 7 ms steps there must be no drift: exactly 30 earned.
        // (The bucket holds two, so that a step's gain is never clipped by a
        // bucket that is momentarily full.)
        let clock = TestClock()
        let limiter = RateLimiter(rate: 3, per: .seconds(1), burst: 2, label: "exact", clock: clock.erased)
        #expect(limiter.tryAcquire(permits: 2))
        var granted = 0
        var elapsed = Duration.zero
        while elapsed < .seconds(10) {
            let step = min(Duration.milliseconds(7), .seconds(10) - elapsed)
            await clock.advance(by: step)
            elapsed += step
            while limiter.tryAcquire() { granted += 1 }
        }
        #expect(granted == 30, "granted \(granted)")
    }

    @Test func aRateOverAnIntervalLongerThanASecond() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 2, per: .seconds(60), burst: 2, label: "slow", clock: clock.erased)
        #expect(limiter.tryAcquire(permits: 2))
        await clock.advance(by: .seconds(29))
        #expect(!limiter.tryAcquire())
        await clock.advance(by: .seconds(1))
        #expect(limiter.tryAcquire())
        #expect(!limiter.tryAcquire())
    }

    @Test func tryAcquireTakesNothingWhenItCannotTakeEverything() {
        let limiter = RateLimiter(rate: 5, burst: 5, label: "all-or-nothing", clock: TestClock().erased)
        #expect(limiter.tryAcquire(permits: 3))
        #expect(!limiter.tryAcquire(permits: 3))
        #expect(limiter.availablePermits == 2)
        #expect(!limiter.tryAcquire(permits: 6))   // more than the bucket holds
        #expect(limiter.availablePermits == 2)
    }

    // MARK: - Waiting

    @Test func waitersAreServedFirstInFirstOutAtTheSteadyRate() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 1, per: .seconds(1), burst: 1, label: "fifo", clock: clock.erased)
        let log = SendableBox<[String]>([])
        #expect(limiter.tryAcquire())
        var tasks: [Task<Rejection?, Never>] = []
        for name in ["a", "b", "c"] {
            tasks.append(waiter(name, limiter: limiter, clock: clock, log: log))
            await waitUntil { limiter.waiterCount == tasks.count }
        }
        await clock.waitForSleepers(count: 1)   // only the head sleeps
        #expect(clock.sleeperCount == 1)
        for second in 1...3 {
            await clock.advance(by: .seconds(1))
            await waitUntil { log.value.count == second }
            if second < 3 { await clock.waitForSleepers(count: 1) }
        }
        for task in tasks { #expect(await task.value == nil) }
        #expect(log.value == ["a@1.0 seconds", "b@2.0 seconds", "c@3.0 seconds"])
        #expect(limiter.waiterCount == 0)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aLargeRequestAtTheHeadBlocksSmallOnesBehindIt() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 1, per: .seconds(1), burst: 3, label: "head-of-line", clock: clock.erased)
        let log = SendableBox<[String]>([])
        #expect(limiter.tryAcquire(permits: 3))
        let big = waiter("big", permits: 3, limiter: limiter, clock: clock, log: log)
        await waitUntil { limiter.waiterCount == 1 }
        let small = waiter("small", permits: 1, limiter: limiter, clock: clock, log: log)
        await waitUntil { limiter.waiterCount == 2 }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(2))   // two permits: enough for small, not for big
        await clock.waitForSleepers(count: 1)
        #expect(log.value.isEmpty)
        await clock.advance(by: .seconds(1))   // big is served; small needs another second
        await waitUntil { log.value.count == 1 }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        _ = await (big.value, small.value)
        #expect(log.value == ["big@3.0 seconds", "small@4.0 seconds"])
    }

    @Test func tryAcquireNeverOvertakesAWaiter() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 1, per: .seconds(1), burst: 2, label: "no-overtake", clock: clock.erased)
        let log = SendableBox<[String]>([])
        #expect(limiter.tryAcquire(permits: 2))
        let big = waiter("big", permits: 2, limiter: limiter, clock: clock, log: log)
        await waitUntil { limiter.waiterCount == 1 }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))   // one permit earned, the waiter needs two
        await clock.waitForSleepers(count: 1)
        #expect(limiter.availablePermits == 1)
        #expect(!limiter.tryAcquire())   // affordable, but a waiter is ahead
        await clock.advance(by: .seconds(1))
        #expect(await big.value == nil)
    }

    // MARK: - Leaving

    @Test func theHeadLeavingHandsItsPlaceToTheNextWaiterAndConsumesNothing() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 1, per: .seconds(1), burst: 1, label: "head-leaves", clock: clock.erased)
        let log = SendableBox<[String]>([])
        #expect(limiter.tryAcquire())
        let first = waiter("first", limiter: limiter, clock: clock, log: log)
        await waitUntil { limiter.waiterCount == 1 }
        let second = waiter("second", limiter: limiter, clock: clock, log: log)
        await waitUntil { limiter.waiterCount == 2 }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(500))
        await clock.waitForSleepers(count: 1)
        first.cancel()
        #expect(await first.value?.reason == .cancelled)
        await waitUntil { limiter.waiterCount == 1 }
        await clock.waitForSleepers(count: 1)   // the second is head and sleeping now
        await clock.advance(by: .milliseconds(500))
        // One permit has been earned since the bucket emptied: the second is
        // served at 1 s, not 2 s, because the first took nothing.
        #expect(await second.value == nil)
        #expect(log.value == ["second@1.0 seconds"])
    }

    @Test func aWaiterBehindTheHeadLeavingConsumesNothing() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 1, per: .seconds(1), burst: 1, label: "tail-leaves", clock: clock.erased)
        let log = SendableBox<[String]>([])
        #expect(limiter.tryAcquire())
        let first = waiter("first", limiter: limiter, clock: clock, log: log)
        await waitUntil { limiter.waiterCount == 1 }
        let second = waiter("second", limiter: limiter, clock: clock, log: log)
        await waitUntil { limiter.waiterCount == 2 }
        await clock.waitForSleepers(count: 1)
        second.cancel()
        #expect(await second.value?.reason == .cancelled)
        #expect(limiter.waiterCount == 1)
        await clock.advance(by: .seconds(1))
        #expect(await first.value == nil)
        await clock.advance(by: .seconds(1))
        #expect(limiter.availablePermits == 1)   // nothing was taken for the one who left
        #expect(log.value == ["first@1.0 seconds"])
    }

    @Test func aTaskCancelledBeforeItReachesTheLimiterIsRefused() async {
        let limiter = RateLimiter(rate: 1, burst: 1, label: "precancel", clock: TestClock().erased)
        let gate = AsyncGate()
        let task = Task { () async -> Rejection? in
            await gate.wait()   // ignores cancellation
            do throws(Rejection) {
                try await limiter.acquire()
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        gate.open()
        #expect(await task.value?.reason == .cancelled)
        #expect(limiter.availablePermits == 1)
    }

    @Test func aDeadlineThatCancelsAQueuedWaiterIsReportedAsOne() async throws {
        // The limiter measures time on one clock and the deadline on another,
        // so the wait looks like it fits when admitted and then the deadline
        // fires first.
        let limiterClock = TestClock()
        let deadlineClock = TestClock()
        let limiter = RateLimiter(rate: 1, per: .seconds(1), burst: 1, label: "deadline-cancel", clock: limiterClock.erased)
        #expect(limiter.tryAcquire())
        let task = Task {
            await withTestAmbient(clock: deadlineClock) { () async -> Rejection? in
                await withTimeout(.seconds(5)) { () async -> Rejection? in
                    do throws(Rejection) {
                        try await limiter.acquire()
                        return nil
                    } catch {
                        return error
                    }
                }
            }
        }
        await waitUntil { limiter.waiterCount == 1 }
        await deadlineClock.waitForSleepers(count: 1)
        await deadlineClock.advance(by: .seconds(5))
        #expect(await task.value?.reason == .deadlineExceeded)
        #expect(limiter.waiterCount == 0)
        await limiterClock.advance(by: .seconds(2))
        #expect(limiter.availablePermits == 1)
    }

    // MARK: - Refusing at once

    @Test func aWaitThatWouldOutliveTheDeadlineIsRefusedAtOnceWithItsLength() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let limiter = RateLimiter(rate: 1, per: .seconds(1), burst: 1, label: "deadline", clock: clock.erased)
        #expect(limiter.tryAcquire())
        await withTestAmbient(clock: clock, events: events) {
            await Deadline.$stored.withValue(.after(.milliseconds(500))) {
                let refusal = await rejection(from: limiter) { unexpected() }
                #expect(refusal?.reason == .rateLimited)
                #expect(refusal?.retryAfter == .seconds(1))
                #expect(refusal?.label == "deadline")
            }
            // A wait that fits is queued, not refused.
            await Deadline.$stored.withValue(.after(.seconds(5))) {
                let task = Task { await rejection(from: limiter) { () async -> Void in } }
                await waitUntil { limiter.waiterCount == 1 }
                await clock.waitForSleepers(count: 1)
                await clock.advance(by: .seconds(1))
                #expect(await task.value == nil)
            }
        }
        #expect(limiter.waiterCount == 0)
        let rejected = events.events(named: "ratelimiter.rejected")
        #expect(rejected.count == 1)
        if case .string(let why)? = rejected.first?["reason"] { #expect(why == "would_exceed_deadline") } else { Issue.record("no reason") }
    }

    @Test func aRefusedRequestConsumesNothingAndQueuesNothing() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 1, per: .seconds(1), burst: 2, label: "untouched", clock: clock.erased)
        #expect(limiter.tryAcquire(permits: 2))
        await withTestAmbient(clock: clock) {
            await Deadline.$stored.withValue(.after(.milliseconds(100))) {
                for _ in 0..<5 { _ = await rejection(from: limiter) { () async -> Void in } }
            }
        }
        #expect(limiter.waiterCount == 0)
        #expect(clock.sleeperCount == 0)
        await clock.advance(by: .seconds(2))
        #expect(limiter.availablePermits == 2)
    }

    @Test func aDeadlineThatHasAlreadyPassedStopsTheOperationStarting() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 5, label: "late", clock: clock.erased)
        await withTestAmbient(clock: clock) {
            let deadline = Deadline.after(.seconds(1))
            await clock.advance(by: .seconds(2))
            await Deadline.$stored.withValue(deadline) {
                let refusal = await rejection(from: limiter) { () throws(Failure) in unexpected() }
                #expect(refusal?.reason == .deadlineExceeded)
            }
        }
        #expect(limiter.availablePermits == 5)
    }

    @Test func aFullQueueRefusesAtOnceWithTheWait() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 1, per: .seconds(1), burst: 1, queueLimit: 1, label: "queue", clock: clock.erased)
        let log = SendableBox<[String]>([])
        #expect(limiter.tryAcquire())
        let first = waiter("first", limiter: limiter, clock: clock, log: log)
        await waitUntil { limiter.waiterCount == 1 }
        let second = waiter("second", limiter: limiter, clock: clock, log: log)
        let refusal = await second.value
        #expect(refusal?.reason == .rateLimited)
        #expect(refusal?.retryAfter == .seconds(2))   // after the one waiting, and then itself
        #expect(limiter.waiterCount == 1)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        #expect(await first.value == nil)
    }

    @Test func aQueueLimitOfZeroNeverWaits() async {
        let limiter = RateLimiter(rate: 1, burst: 1, queueLimit: 0, label: "no-queue", clock: TestClock().erased)
        #expect(await rejection(from: limiter) { () async -> Void in } == nil)
        let refusal = await rejection(from: limiter) { () async -> Void in }
        #expect(refusal?.reason == .rateLimited)
        #expect(refusal?.retryAfter == .seconds(1))
    }

    @Test func aRequestLargerThanTheBurstIsRefusedForever() async {
        let events = RecordingInstrumentation()
        let limiter = RateLimiter(rate: 5, burst: 5, label: "oversized", clock: TestClock().erased)
        await withTestAmbient(clock: ImmediateClock(), events: events) {
            do throws(Rejection) {
                try await limiter.acquire(permits: 6)
                unexpected("expected a rejection")
            } catch {
                #expect(error.reason == .rateLimited)
                #expect(error.retryAfter == nil)
            }
        }
        #expect(events.names == ["ratelimiter.oversized"])
        #expect(limiter.availablePermits == 5)
    }

    // MARK: - execute

    @Test func executeRunsTheOperationAndKeepsTheTokenSpentWhenItFails() async {
        let clock = TestClock()
        let limiter = RateLimiter(rate: 1, burst: 2, label: "execute", clock: clock.erased)
        let value = await outcome(of: limiter) { 7 }
        if case .success(let number) = value { #expect(number == 7) } else { unexpected("expected a value") }
        let failed = await outcome(of: limiter) { () throws(Failure) in throw .boom }
        if case .failure(let error) = failed { #expect(error.failure == .boom) } else { unexpected("expected a failure") }
        #expect(limiter.availablePermits == 0)
    }

    // MARK: - Properties

    @Test func grantedPermitsNeverExceedBurstPlusRateTimesElapsed() async {
        // Random schedules of advances and requests of random sizes, over
        // random rates, bursts and intervals: at every step the permits
        // granted are at most burst + rate × elapsed, in exact arithmetic.
        for seed in 1...40 as ClosedRange<UInt64> {
            var generator = RandomSource.seeded(seed).generator()
            let rate = Int.random(in: 1...20, using: &generator)
            let burst = Int.random(in: 1...30, using: &generator)
            let interval = Duration.milliseconds(Int.random(in: 50...3000, using: &generator))
            let clock = TestClock()
            let limiter = RateLimiter(rate: rate, per: interval, burst: burst, label: "property", clock: clock.erased)
            var grantedUnits: Int128 = 0
            var elapsed = Duration.zero
            for _ in 0..<200 {
                let step = Duration.milliseconds(Int.random(in: 0...400, using: &generator))
                await clock.advance(by: step)
                elapsed += step
                for _ in 0..<Int.random(in: 0...4, using: &generator) {
                    let permits = Int.random(in: 1...burst, using: &generator)
                    if limiter.tryAcquire(permits: permits) { grantedUnits += Int128(permits) }
                }
                // granted × interval ≤ burst × interval + rate × elapsed, all in attoseconds.
                let bound = Int128(burst) * interval.attoseconds + Int128(rate) * elapsed.attoseconds
                #expect(grantedUnits * interval.attoseconds <= bound, "seed \(seed)")
            }
        }
    }

    @Test func aGreedyCallerGetsExactlyBurstPlusRateTimesElapsed() async {
        for seed in 1...20 as ClosedRange<UInt64> {
            var generator = RandomSource.seeded(seed).generator()
            let rate = Int.random(in: 1...20, using: &generator)
            let burst = Int.random(in: 2...30, using: &generator)
            // Steps are short enough that one never earns a whole permit, so
            // a step's gain is never clipped by a bucket that is full.
            let interval = Duration.milliseconds(Int.random(in: 500...3000, using: &generator))
            let clock = TestClock()
            let limiter = RateLimiter(rate: rate, per: interval, burst: burst, label: "greedy", clock: clock.erased)
            var granted: Int128 = 0
            while limiter.tryAcquire() { granted += 1 }   // drain the burst before any time passes
            var elapsed = Duration.zero
            for _ in 0..<3000 {
                let step = Duration.milliseconds(Int.random(in: 1...20, using: &generator))
                await clock.advance(by: step)
                elapsed += step
                while limiter.tryAcquire() { granted += 1 }
                // Every permit that could be granted has been: granted is the
                // floor of burst + rate × elapsed / interval.
                let earned = (Int128(rate) * elapsed.attoseconds) / interval.attoseconds
                #expect(granted == Int128(burst) + earned, "seed \(seed)")
            }
        }
    }

    @Test func waitersAreServedExactlyWhenTheModelSaysAndInOrder() async {
        for seed in 1...15 as ClosedRange<UInt64> {
            var generator = RandomSource.seeded(seed).generator()
            let rate = Int.random(in: 1...5, using: &generator)
            let burst = Int.random(in: 3...8, using: &generator)
            let clock = TestClock()
            let limiter = RateLimiter(rate: rate, per: .seconds(1), burst: burst, queueLimit: nil, label: "model", clock: clock.erased)
            #expect(limiter.tryAcquire(permits: burst))   // start empty
            // Costs below the burst and steps below one permit's worth of
            // time keep the bucket from ever overflowing mid-step, which is
            // what lets a model that refills once per step be exact.
            let costs = (0..<12).map { _ in Int.random(in: 1...(burst - 1), using: &generator) }
            let served = SendableBox<[Int]>([])
            var tasks: [Task<Void, Never>] = []
            for (index, cost) in costs.enumerated() {
                tasks.append(Task {
                    do throws(Rejection) {
                        try await limiter.acquire(permits: cost)
                        served.mutate { $0.append(index) }
                    } catch {
                        Issue.record(Comment(rawValue: "unexpected rejection \(error)"))
                    }
                })
                await waitUntil { limiter.waiterCount == index + 1 }
            }
            // The model: credit in 1/1000-permit units, one millisecond a step.
            var credit = 0
            var next = 0
            var model: [Int] = []
            let capacity = burst * 1000
            while model.count < costs.count {
                await clock.waitForSleepers(count: 1)
                let step = Int.random(in: 1...(1000 / rate), using: &generator)
                await clock.advance(by: .milliseconds(step))
                credit = min(capacity, credit + step * rate)
                while next < costs.count, credit >= costs[next] * 1000 {
                    credit -= costs[next] * 1000
                    model.append(next)
                    next += 1
                }
                let expected = model.count
                await waitUntil("seed \(seed): served \(served.value.count) of \(expected)") { served.value.count == expected }
            }
            for task in tasks { await task.value }
            #expect(served.value == Array(0..<costs.count), "seed \(seed)")
            #expect(limiter.waiterCount == 0)
        }
    }

    @Test func manyConcurrentCallersAndRandomCancellationsLeakNothing() async {
        // On the immediate clock every sleep returns at once, advancing time,
        // so the limiter runs as fast as the scheduler allows.
        let clock = ImmediateClock()
        let limiter = RateLimiter(rate: 100, per: .seconds(1), burst: 10, queueLimit: nil, label: "stress", clock: clock.erased)
        let served = SendableBox(0)
        var generator = RandomSource.seeded(3).generator()
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<300 {
            let task = Task {
                if (try? await limiter.acquire()) != nil { served.mutate { $0 += 1 } }
            }
            tasks.append(task)
            if Int.random(in: 0..<4, using: &generator) == 0 {
                if Bool.random(using: &generator) { await Task.yield() }
                task.cancel()
            }
        }
        for task in tasks { await task.value }
        #expect(limiter.waiterCount == 0)
        // Everything served was paid for: 10 for the burst, 100 a second after.
        let elapsed = clock.now.offset
        let earned = 10 + Int((elapsed.seconds * 100).rounded(.down))
        #expect(served.value <= earned)
        #expect(served.value > 150)
    }
}
