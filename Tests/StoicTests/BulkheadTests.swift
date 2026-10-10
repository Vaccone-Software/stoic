@testable import Stoic
import StoicTesting
import Testing

@Suite("Bulkhead")
struct BulkheadTests {
    enum Failure: Error, Equatable { case boom }

    @Test func runsAtOnceWhenASlotIsFree() async throws {
        let bulkhead = Bulkhead(maxConcurrent: 2, label: "free")
        let value = try await bulkhead.execute { 42 }
        #expect(value == 42)
        #expect(bulkhead.activeCount == 0)
    }

    @Test func concurrencyNeverExceedsTheLimit() async throws {
        let bulkhead = Bulkhead(maxConcurrent: 4, queueLimit: 400, label: "stress")
        let gauge = SendableBox((current: 0, peak: 0, ran: 0))
        try await withThrowingTaskGroup { group in
            for _ in 0..<300 {
                group.addTask {
                    try await bulkhead.execute {
                        gauge.mutate { $0.current += 1; $0.peak = max($0.peak, $0.current) }
                        await Task.yield()
                        gauge.mutate { $0.current -= 1; $0.ran += 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(gauge.value.peak <= 4)
        #expect(gauge.value.peak >= 1)
        #expect(gauge.value.ran == 300)
        #expect(bulkhead.activeCount == 0)
        #expect(bulkhead.queuedCount == 0)
    }

    @Test func aFullBulkheadWithNoQueueRejectsAtOnce() async throws {
        let events = RecordingInstrumentation()
        let bulkhead = Bulkhead(maxConcurrent: 1, label: "shed")
        let gate = AsyncGate()
        let holder = Task { try await bulkhead.execute { await gate.wait() } }
        while bulkhead.activeCount < 1 { await Task.yield() }
        await withTestAmbient(clock: ImmediateClock(), events: events) {
            let refusal = await rejection(from: bulkhead) { () throws(Failure) in unexpected() }
            #expect(refusal?.reason == .bulkheadFull)
            #expect(refusal?.label == "shed")
        }
        let rejected = events.events(named: "bulkhead.rejected")
        #expect(rejected.count == 1)
        #expect(rejected.first?.label == "shed")
        if case .string(let reason)? = rejected.first?["reason"] { #expect(reason == "bulkhead_full") } else { Issue.record("no reason") }
        gate.open()
        try await holder.value
    }

    @Test func theQueueLimitIsExactUnderSimultaneousArrivals() async throws {
        // Two slots, three queue places: of fifty tasks that arrive together
        // against a closed gate, exactly five are admitted.
        let bulkhead = Bulkhead(maxConcurrent: 2, queueLimit: 3, label: "exact")
        let gate = AsyncGate()
        let outcomes = SendableBox((rejected: 0, ran: 0))
        let tasks = (0..<50).map { _ in
            Task {
                let refusal = await rejection(from: bulkhead) {
                    await gate.wait()
                    outcomes.mutate { $0.ran += 1 }
                }
                if let refusal {
                    #expect(refusal.reason == .bulkheadFull)
                    outcomes.mutate { $0.rejected += 1 }
                }
            }
        }
        while outcomes.value.rejected < 45 { await Task.yield() }
        #expect(bulkhead.activeCount == 2)
        #expect(bulkhead.queuedCount == 3)
        gate.open()
        for task in tasks { await task.value }
        #expect(outcomes.value.ran == 5)
        #expect(outcomes.value.rejected == 45)
    }

    @Test func waitersRunFirstInFirstOut() async throws {
        let bulkhead = Bulkhead(maxConcurrent: 1, queueLimit: 5, label: "fifo")
        let gate = AsyncGate()
        let order = OrderLog()
        let holder = Task { try await bulkhead.execute { await gate.wait() } }
        while bulkhead.activeCount < 1 { await Task.yield() }
        var waiters: [Task<Void, any Error>] = []
        for index in 0..<5 {
            waiters.append(Task { try await bulkhead.execute { order.append("\(index)") } })
            while bulkhead.queuedCount < index + 1 { await Task.yield() }
        }
        gate.open()
        try await holder.value
        for waiter in waiters { try await waiter.value }
        #expect(order.values == ["0", "1", "2", "3", "4"])
    }

    @Test func aCancelledWaiterLeavesWithoutTakingASlotAndFreesItsPlace() async throws {
        let bulkhead = Bulkhead(maxConcurrent: 1, queueLimit: 1, label: "cancel")
        let gate = AsyncGate()
        let holder = Task { try await bulkhead.execute { await gate.wait() } }
        while bulkhead.activeCount < 1 { await Task.yield() }
        let waiter = Task { try await bulkhead.execute { unexpected() } }
        while bulkhead.queuedCount < 1 { await Task.yield() }
        waiter.cancel()
        do {
            try await waiter.value
            unexpected("expected a rejection")
        } catch let error as PolicyError<Never> {
            #expect(error.rejection?.reason == .cancelled)
        }
        #expect(bulkhead.queuedCount == 0)
        // The place is free again.
        let next = Task { try await bulkhead.execute { "ran" } }
        while bulkhead.queuedCount < 1 { await Task.yield() }
        gate.open()
        try await holder.value
        #expect(try await next.value == "ran")
        #expect(bulkhead.activeCount == 0)
    }

    @Test func aWaiterWhoseDeadlinePassesIsRejected() async throws {
        let clock = TestClock()
        let bulkhead = Bulkhead(maxConcurrent: 1, queueLimit: 1, label: "deadline")
        let gate = AsyncGate()
        let holder = Task { try await bulkhead.execute { await gate.wait() } }
        while bulkhead.activeCount < 1 { await Task.yield() }
        let waiter = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(5)) {
                    try await bulkhead.execute { () throws(Failure) in unexpected() }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(5))
        do {
            try await waiter.value
            unexpected("expected a rejection")
        } catch let error as PolicyError<Failure> {
            #expect(error.rejection?.reason == .deadlineExceeded)
        }
        gate.open()
        try await holder.value
        #expect(bulkhead.activeCount == 0)
        #expect(bulkhead.queuedCount == 0)
    }

    @Test func aDeadlineThatHasAlreadyPassedStopsTheOperationStarting() async throws {
        let clock = TestClock()
        let bulkhead = Bulkhead(maxConcurrent: 1, label: "late")
        await withTestAmbient(clock: clock) {
            let deadline = Deadline.after(.seconds(1))
            await clock.advance(by: .seconds(2))
            await Deadline.$stored.withValue(deadline) {
                let refusal = await rejection(from: bulkhead) { () throws(Failure) in unexpected() }
                #expect(refusal?.reason == .deadlineExceeded)
            }
        }
    }

    @Test func aTaskCancelledBeforeAdmissionIsRejectedCancelled() async throws {
        let bulkhead = Bulkhead(maxConcurrent: 1, label: "precancel")
        let gate = AsyncGate()
        let task = Task {
            await gate.wait()   // ignores cancellation, so the task is cancelled before it reaches the bulkhead
            return await rejection(from: bulkhead) { unexpected() }
        }
        task.cancel()
        gate.open()
        #expect(await task.value?.reason == .cancelled)
        #expect(bulkhead.activeCount == 0)
    }

    @Test func aFailingOperationReturnsItsSlot() async {
        let bulkhead = Bulkhead(maxConcurrent: 1, label: "fail")
        let result = await outcome(of: bulkhead) { () throws(Failure) in throw .boom }
        if case .failure(let error) = result { #expect(error.failure == .boom) } else { unexpected("expected a failure") }
        #expect(bulkhead.activeCount == 0)
    }

    @Test func randomCancellationsNeverLeakSlots() async throws {
        let bulkhead = Bulkhead(maxConcurrent: 2, queueLimit: 100, label: "model")
        var generator = RandomSource.seeded(5).generator()
        var tasks: [Task<Void, any Error>] = []
        for _ in 0..<200 {
            let task = Task { try await bulkhead.execute { await Task.yield() } }
            tasks.append(task)
            if Int.random(in: 0..<3, using: &generator) == 0 {
                if Bool.random(using: &generator) { await Task.yield() }
                task.cancel()
            }
        }
        for task in tasks { _ = try? await task.value }
        #expect(bulkhead.activeCount == 0)
        #expect(bulkhead.queuedCount == 0)
    }
}
