@testable import Stoic
import StoicTesting
import Testing

@Suite("AsyncSemaphore")
struct SemaphoreTests {
    enum Failure: Error, Equatable { case boom }

    @Test func neverRunsMoreBodiesThanPermits() async throws {
        let semaphore = AsyncSemaphore(permits: 3, label: "test")
        let gauge = SendableBox((current: 0, peak: 0))
        try await withThrowingTaskGroup { group in
            for _ in 0..<50 {
                group.addTask {
                    try await semaphore.withPermit {
                        gauge.mutate { $0.current += 1; $0.peak = max($0.peak, $0.current) }
                        await Task.yield()
                        gauge.mutate { $0.current -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(gauge.value.peak <= 3)
        #expect(gauge.value.peak >= 1)
        #expect(semaphore.availablePermits == 3)
    }

    @Test func grantsPermitsFirstInFirstOut() async throws {
        let semaphore = AsyncSemaphore(permits: 1, label: "fifo")
        let gate = AsyncGate()
        let order = OrderLog()
        let holder = Task { try await semaphore.withPermit { await gate.wait() } }
        while semaphore.availablePermits > 0 { await Task.yield() }
        var waiters: [Task<Void, any Error>] = []
        for index in 0..<5 {
            waiters.append(Task { try await semaphore.withPermit { order.append("\(index)") } })
            while semaphore.waiterCount < index + 1 { await Task.yield() }
        }
        gate.open()
        try await holder.value
        for waiter in waiters { try await waiter.value }
        #expect(order.values == ["0", "1", "2", "3", "4"])
    }

    @Test func aCancelledWaiterLeavesWithoutConsumingAPermit() async throws {
        let semaphore = AsyncSemaphore(permits: 1, label: "cancel")
        let gate = AsyncGate()
        let holder = Task { try await semaphore.withPermit { await gate.wait() } }
        while semaphore.availablePermits > 0 { await Task.yield() }
        let waiter = Task { try await semaphore.withPermit { _ = Issue.record("a cancelled waiter must not run") } }
        while semaphore.waiterCount < 1 { await Task.yield() }
        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("expected a rejection")
        } catch let error as PolicyError<Never> {
            #expect(error.rejection?.reason == .cancelled)
        }
        #expect(semaphore.waiterCount == 0)
        gate.open()
        try await holder.value
        #expect(semaphore.availablePermits == 1)
    }

    @Test func aWaiterWhoseDeadlinePassesIsRejected() async throws {
        let clock = TestClock()
        let semaphore = AsyncSemaphore(permits: 1, label: "deadline")
        let gate = AsyncGate()
        let holder = Task { try await semaphore.withPermit { await gate.wait() } }
        while semaphore.availablePermits > 0 { await Task.yield() }
        let waiter = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(5)) {
                    try await semaphore.withPermit { () throws(Failure) in }
                }
            }
        }
        await clock.waitForSleepers(count: 2)   // the timeout's timer and the waiter's
        await clock.advance(by: .seconds(5))
        do {
            try await waiter.value
            Issue.record("expected a rejection")
        } catch let error as PolicyError<Failure> {
            #expect(error.rejection?.reason == .deadlineExceeded)
        }
        gate.open()
        try await holder.value
        #expect(semaphore.availablePermits == 1)
        #expect(semaphore.waiterCount == 0)
    }

    @Test func aFailingBodyReturnsItsPermit() async {
        let semaphore = AsyncSemaphore(permits: 1, label: "fail")
        await #expect(throws: PolicyError<Failure>.self) {
            try await semaphore.withPermit { () throws(Failure) in throw .boom }
        }
        #expect(semaphore.availablePermits == 1)
    }

    @Test func reacquiringAHeldSemaphoreIsReported() async throws {
        let events = RecordingInstrumentation()
        let semaphore = AsyncSemaphore(permits: 2, label: "reentrant")
        try await withTestAmbient(clock: ImmediateClock(), events: events) {
            try await semaphore.withPermit {
                try await semaphore.withPermit {}
            }
        }
        #expect(events.names == ["semaphore.reentrant"])
    }

    @Test func randomCancellationsNeverLeakPermits() async throws {
        // Model check: many waiters, a random third cancelled at random
        // moments. At the end every permit is back and nobody is queued.
        let semaphore = AsyncSemaphore(permits: 2, label: "model")
        var generator = RandomSource.seeded(11).generator()
        var tasks: [Task<Void, any Error>] = []
        for _ in 0..<200 {
            let task = Task { try await semaphore.withPermit { await Task.yield() } }
            tasks.append(task)
            if Int.random(in: 0..<3, using: &generator) == 0 {
                if Bool.random(using: &generator) { await Task.yield() }
                task.cancel()
            }
        }
        for task in tasks { _ = try? await task.value }
        #expect(semaphore.availablePermits == 2)
        #expect(semaphore.waiterCount == 0)
    }

    @Test func asyncMutexSerialisesAcrossAwaits() async throws {
        let mutex = AsyncMutex(label: "mutex")
        let state = SendableBox((inside: 0, overlapped: false))
        try await withThrowingTaskGroup { group in
            for _ in 0..<20 {
                group.addTask {
                    try await mutex.withLock {
                        state.mutate { $0.overlapped = $0.overlapped || $0.inside > 0; $0.inside += 1 }
                        await Task.yield()
                        state.mutate { $0.inside -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(state.value.overlapped == false)
    }
}
