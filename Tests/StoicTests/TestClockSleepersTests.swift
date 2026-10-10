@testable import Stoic
@testable import StoicTesting
import Synchronization
import Testing

@Suite("TestClock sleepers")
struct TestClockSleepersTests {
    @Test func sleepersWakeInDeadlineOrderThenInTheOrderTheyWentToSleep() async throws {
        let clock = TestClock()
        let woken = Mutex<[Int]>([])
        await withTaskGroup(of: Void.self) { group in
            // Deadlines 3, 1, 2, 1, 3, 2 seconds: ids 0..5 in that order.
            for (id, seconds) in [3, 1, 2, 1, 3, 2].enumerated() {
                group.addTask {
                    try? await clock.sleep(until: clock.now.advanced(by: .seconds(seconds)))
                    woken.withLock { $0.append(id) }
                }
                await clock.waitForSleepers(count: id + 1)
            }
            await clock.advance(by: .seconds(3))
            await clock.waitForSleepers(count: 0)
        }
        #expect(woken.withLock { $0 } == [1, 3, 2, 5, 0, 4])
    }

    @Test func aCancelledSleeperLeavesNoGhostInTheOrder() async throws {
        let clock = TestClock()
        let order = Mutex<[String]>([])
        let doomed = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(1))) }
        await clock.waitForSleepers(count: 1)
        let kept = Task {
            try await clock.sleep(until: clock.now.advanced(by: .seconds(2)))
            order.withLock { $0.append("kept") }
        }
        await clock.waitForSleepers(count: 2)
        doomed.cancel()
        _ = await doomed.result
        #expect(clock.sleeperCount == 1)
        #expect(clock.pendingDeadlines == [TestClock.Instant(offset: .seconds(2))])
        #expect(clock.fireNextDeadline() == TestClock.Instant(offset: .seconds(2)))
        try await kept.value
        #expect(order.withLock { $0 } == ["kept"])
        #expect(clock.fireNextDeadline() == nil)
    }

    @Test func manyCancelledSleepersDoNotAccumulate() async throws {
        let clock = TestClock()
        for round in 0..<200 {
            let tasks = (0..<50).map { _ in Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(3600 + round))) } }
            await clock.waitForSleepers(count: 50)
            for task in tasks { task.cancel() }
            for task in tasks { _ = await task.result }
        }
        #expect(clock.sleeperCount == 0)
        #expect(clock.fireNextDeadline() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func thirtyThousandTimersFireInLinearishTime() async throws {
        // Finding the earliest deadline used to scan every sleeper, per
        // fire: 30,000 distinct deadlines took minutes in a debug build.
        let clock = TestClock()
        let count = 30_000
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask { try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(index + 1))) }
            }
            await clock.waitForSleepers(count: count)
            var fired = 0
            while clock.fireNextDeadline() != nil { fired += 1 }
            #expect(fired == count)
        }
    }

    @Test func cancellingAllSleepersWakesThemWithoutMovingTime() async throws {
        let clock = TestClock()
        let outcomes = Mutex<[Bool]>([])
        let tasks = (0..<3).map { index in
            Task {
                do { try await clock.sleep(until: clock.now.advanced(by: .seconds(100 + index))) }
                catch { outcomes.withLock { $0.append(error is CancellationError) } }
            }
        }
        await clock.waitForSleepers(count: 3)
        #expect(clock.cancelAllSleepers() == 3)
        for task in tasks { await task.value }
        #expect(outcomes.withLock { $0 } == [true, true, true])
        #expect(clock.now == TestClock.Instant(offset: .zero))
        #expect(clock.sleeperCount == 0)
    }
}
