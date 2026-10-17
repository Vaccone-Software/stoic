import Stoic
import StoicApple
import StoicTesting
import Testing

/// Runs `body` in a task whose typed failure is kept as a value.
func capture(
    _ body: @escaping @Sendable () async throws(ReachabilityError) -> NetworkPath
) -> Task<Result<NetworkPath, ReachabilityError>, Never> {
    Task {
        do throws(ReachabilityError) {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}

@Suite("Reachability")
struct ReachabilityTests {
    static let constrained = NetworkPath(status: .satisfied, isConstrained: true)
    static let expensive = NetworkPath(status: .satisfied, isExpensive: true)

    @Test(.failureMode("design/21", "the first path arrives"))
    func theFirstPathIsDeliveredAtOnce() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let monitor = FakePathMonitor(.unsatisfied)
            var paths = monitor.stablePaths(settle: .seconds(1)).makeAsyncIterator()
            #expect(await paths.next() == .unsatisfied)
            #expect(clock.totalSleeps == 0)
        }
    }

    @Test(.failureMode("design/21", "the network flaps for less than the settle time"))
    func aGlitchShorterThanTheSettleTimeIsNeverDelivered() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let monitor = FakePathMonitor(.satisfied)
            var paths = monitor.stablePaths(settle: .seconds(1)).makeAsyncIterator()
            #expect(await paths.next() == .satisfied)
            monitor.send(.unsatisfied)
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(400))
            monitor.send(.satisfied)   // back before the settle time: a glitch
            // A real change follows. Were the glitch delivered, it would come first.
            let mark = clock.totalSleeps
            monitor.send(Self.constrained)
            await clock.waitForSleepers(newerThan: mark)
            await clock.advance(by: .seconds(1))
            #expect(await paths.next() == Self.constrained)
        }
    }

    @Test(.failureMode("design/21", "a change holds for the settle time"))
    func aChangeIsDeliveredOnceItHasSettled() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let monitor = FakePathMonitor(.satisfied)
            var paths = monitor.stablePaths(settle: .seconds(1)).makeAsyncIterator()
            #expect(await paths.next() == .satisfied)
            monitor.send(.unsatisfied)
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(999))
            #expect(clock.sleeperCount == 1)   // still waiting: nothing has been delivered
            await clock.advance(by: .milliseconds(1))
            #expect(await paths.next() == .unsatisfied)
        }
    }

    @Test func aZeroSettleTimeDeliversEveryPath() async {
        let monitor = FakePathMonitor(.satisfied)
        var paths = monitor.stablePaths(settle: .zero).makeAsyncIterator()
        monitor.send(.unsatisfied)
        monitor.send(.satisfied)
        #expect(await paths.next() == .satisfied)
        #expect(await paths.next() == .unsatisfied)
        #expect(await paths.next() == .satisfied)
    }

    @Test func waitUntilReachableReturnsAtOnceWhenTheNetworkIsUp() async throws {
        let monitor = FakePathMonitor(.satisfied)
        #expect(try await monitor.waitUntilReachable() == .satisfied)
    }

    @Test func waitUntilReachableWaitsForTheNetworkToComeBack() async throws {
        let monitor = FakePathMonitor(.unsatisfied)
        let task = capture { () async throws(ReachabilityError) -> NetworkPath in
            try await monitor.waitUntilReachable(settle: .zero)
        }
        await monitor.waitForSubscribers(1)
        monitor.send(.satisfied)
        #expect(try await task.value.get() == .satisfied)
    }

    @Test(.failureMode("design/21", "the path is up but expensive or constrained and the caller refuses that"))
    func anUnacceptablePathKeepsTheCallerWaiting() async throws {
        for (bad, refusal) in [(Self.expensive, 0), (Self.constrained, 1)] {
            let monitor = FakePathMonitor(bad)
            let task = capture { () async throws(ReachabilityError) -> NetworkPath in
                try await monitor.waitUntilReachable(
                    allowsExpensive: refusal != 0, allowsConstrained: refusal != 1, settle: .zero)
            }
            await monitor.waitForSubscribers(1)
            monitor.send(.satisfied)
            #expect(try await task.value.get() == .satisfied)
        }
    }

    @Test(.failureMode("design/21", "the deadline passes while waiting"))
    func theDeadlineEndsTheWait() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let monitor = FakePathMonitor(.unsatisfied)
            let deadline = Deadline.after(.seconds(30), clock: clock.erased)
            let task = capture { () async throws(ReachabilityError) -> NetworkPath in
                try await monitor.waitUntilReachable(until: deadline)
            }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(30))
            let result = await task.value
            guard case .failure(.deadlineExceeded(let last)) = result else {
                Issue.record("expected deadlineExceeded, got \(result)")
                return
            }
            // The path the waiter had seen when time ran out: it may not yet have read the first.
            #expect(last == .unsatisfied || last == nil)
        }
    }

    @Test(.failureMode("design/21", "the caller is already inside a deadline"))
    func theEarlierOfTheTwoDeadlinesApplies() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let monitor = FakePathMonitor(.unsatisfied)
            let outer = Deadline.after(.seconds(10), clock: clock.erased)
            let longer = Deadline.after(.seconds(60), clock: clock.erased)
            let task = capture { () async throws(ReachabilityError) -> NetworkPath in
                try await withDeadline(outer) { () async throws(ReachabilityError) -> NetworkPath in
                    try await monitor.waitUntilReachable(until: longer)
                }
            }
            // The outer deadline's timer only: the wait's own deadline is the
            // same instant, so it narrows nothing and starts no timer.
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(10))
            let result = await task.value
            guard case .failure(.deadlineExceeded) = result else {
                Issue.record("expected deadlineExceeded, got \(result)")
                return
            }
        }
    }

    @Test(.failureMode("design/21", "the waiting task is cancelled"))
    func cancellingTheWaiterStopsTheMonitor() async {
        let monitor = FakePathMonitor(.unsatisfied)
        let task = capture { () async throws(ReachabilityError) -> NetworkPath in
            try await monitor.waitUntilReachable()
        }
        await monitor.waitForSubscribers(1)
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
        await monitor.waitUntilIdle()
        #expect(monitor.subscriberCount == 0)
    }

    @Test(.failureMode("design/21", "the monitor ends before the network returns"))
    func aMonitorThatEndsEndsTheWait() async {
        let monitor = FakePathMonitor(.unsatisfied)
        let task = capture { () async throws(ReachabilityError) -> NetworkPath in
            try await monitor.waitUntilReachable()
        }
        await monitor.waitForSubscribers(1)
        monitor.finish()
        #expect(await task.value == .failure(.monitorEnded))
    }

    /// A stream holds its own lock while it runs its termination handler, and
    /// the handlers of the debounce and of the fake monitor take their own
    /// locks: a path yielded while holding one deadlocked against a consumer
    /// that stopped listening at that moment. A deadlock is not something a
    /// time limit can end: the threads that would enforce it are the ones stuck.
    @Test(.failureMode("design/21", "the consumer stops listening"))
    func aConsumerThatStopsWhilePathsArriveBlocksNeitherSide() async {
        let monitor = FakePathMonitor(.satisfied)
        let stop = SendableBox(false)
        let sender = Task {
            var up = false
            while !stop.value {
                monitor.send(up ? .satisfied : .unsatisfied)
                up.toggle()
                await Task.yield()
            }
        }
        for _ in 0..<2_000 {
            let consumer = Task { for await _ in monitor.stablePaths(settle: .zero) {} }
            await Task.yield()
            consumer.cancel()
            await consumer.value
        }
        stop.mutate { $0 = true }
        await sender.value
        await monitor.waitUntilIdle()
        #expect(monitor.subscriberCount == 0)
    }

    @Test(.failureMode("design/21", "the consumer stops listening"))
    func aConsumerThatStopsLeavesNothingRunning() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let monitor = FakePathMonitor(.satisfied)
            let seen = SendableBox(0)
            let task = Task {
                for await _ in monitor.stablePaths() { seen.mutate { $0 += 1 } }
            }
            await monitor.waitForSubscribers(1)
            monitor.send(.unsatisfied)
            await clock.waitForSleepers(count: 1)   // a change is pending
            task.cancel()
            await task.value
            await monitor.waitUntilIdle()
            #expect(monitor.subscriberCount == 0)
            #expect(clock.sleeperCount == 0)
        }
    }
}
