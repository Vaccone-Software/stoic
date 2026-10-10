@testable import Stoic
import StoicTesting
import Testing

@Suite("Channel")
struct ChannelTests {
    @Test func elementsArriveInOrderAndTheChannelDrainsAfterFinish() async throws {
        let channel = Channel<Int>(capacity: 4, label: "numbers")
        let consumer = Task { () -> [Int] in
            var received: [Int] = []
            for await value in channel { received.append(value) }
            return received
        }
        for value in 0..<100 { try await channel.send(value) }
        channel.finish()
        #expect(await consumer.value == Array(0..<100))
    }

    @Test func aFullChannelSuspendsTheSender() async throws {
        let channel = Channel<Int>(capacity: 2, label: "backpressure")
        try await channel.send(1)
        try await channel.send(2)
        let blocked = Task { try await channel.send(3) }
        for _ in 0..<50 { await Task.yield() }
        #expect(channel.count == 2)
        #expect(await channel.receive() == 1)
        try await blocked.value
        #expect(await channel.receive() == 2)
        #expect(await channel.receive() == 3)
    }

    @Test func dropOldestKeepsTheLatest() async throws {
        let channel = Channel<Int>(capacity: 3, overflow: .dropOldest, label: "progress")
        for value in 0..<10 { try await channel.send(value) }
        channel.finish()
        var received: [Int] = []
        for await value in channel { received.append(value) }
        #expect(received == [7, 8, 9])
        #expect(channel.droppedCount == 7)
    }

    @Test func dropNewestKeepsTheFirst() async throws {
        let channel = Channel<Int>(capacity: 3, overflow: .dropNewest, label: "first")
        for value in 0..<10 { try await channel.send(value) }
        channel.finish()
        var received: [Int] = []
        for await value in channel { received.append(value) }
        #expect(received == [0, 1, 2])
    }

    @Test func rejectThrowsWhenFull() async throws {
        let channel = Channel<Int>(capacity: 1, overflow: .reject, label: "shed")
        try await channel.send(1)
        await #expect(throws: Rejection.self) { try await channel.send(2) }
        #expect(!channel.trySend(3))
    }

    @Test func aCancelledSenderSendsNothing() async throws {
        let channel = Channel<Int>(capacity: 1, label: "cancel")
        try await channel.send(1)
        let blocked = Task { try await channel.send(2) }
        for _ in 0..<50 { await Task.yield() }
        blocked.cancel()
        do {
            try await blocked.value
            Issue.record("expected a rejection")
        } catch let rejection as Rejection {
            #expect(rejection.reason == .cancelled)
        }
        channel.finish()
        var received: [Int] = []
        for await value in channel { received.append(value) }
        #expect(received == [1])
    }

    @Test func aSenderWhoseDeadlinePassesIsRejected() async throws {
        let clock = TestClock()
        let channel = Channel<Int>(capacity: 1, label: "deadline")
        try await channel.send(1)
        let blocked = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(2)) { try await channel.send(2) }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(2))
        do {
            try await blocked.value
            Issue.record("expected a rejection")
        } catch let rejection as Rejection {
            #expect(rejection.reason == .deadlineExceeded)
        }
        #expect(channel.count == 1)
    }

    @Test func finishingRejectsWaitingSendersAndEndsWaitingReceivers() async throws {
        let full = Channel<Int>(capacity: 1, label: "full")
        try await full.send(1)
        let sender = Task { try await full.send(2) }
        for _ in 0..<50 { await Task.yield() }
        full.finish()
        do {
            try await sender.value
            Issue.record("expected a rejection")
        } catch let rejection as Rejection {
            #expect(rejection.reason == .closed)
        }
        let empty = Channel<Int>(capacity: 1, label: "empty")
        let receiver = Task { await empty.receive() }
        for _ in 0..<50 { await Task.yield() }
        empty.finish()
        #expect(await receiver.value == nil)
        await #expect(throws: Rejection.self) { try await empty.send(1) }
    }

    @Test func manyProducersAndConsumersLoseNothing() async throws {
        let channel = Channel<Int>(capacity: 8, label: "stress")
        let total = SendableBox(0)
        let count = SendableBox(0)
        await withTaskGroup { group in
            for consumer in 0..<4 {
                _ = consumer
                group.addTask {
                    for await value in channel {
                        total.mutate { $0 += value }
                        count.mutate { $0 += 1 }
                    }
                }
            }
            await withThrowingTaskGroup { producers in
                for producer in 0..<8 {
                    producers.addTask {
                        for value in 0..<250 { try await channel.send(producer * 1000 + value) }
                    }
                }
                try? await producers.waitForAll()
            }
            channel.finish()
        }
        let expected = (0..<8).reduce(0) { sum, producer in sum + (0..<250).reduce(0) { $0 + producer * 1000 + $1 } }
        #expect(count.value == 2000)
        #expect(total.value == expected)
    }
}

@Suite("Channel: delivery racing cancellation")
struct ChannelCancellationRaceTests {
    /// Runs `round` in a loop on its own task for `duration`, and reports
    /// whether progress stalled: a deadlock shows as a counter that stops
    /// *and stays stopped*. A single quiet window proves nothing: under a
    /// loaded machine (the whole suite, repeated) the pool can starve these
    /// busy loops for a quarter of a second at a time. So a stall is no
    /// progress for `patience` straight, long enough for any starvation to
    /// pass and a real deadlock (which never recovers) to be certain.
    func runsWithoutStalling(
        for duration: Duration,
        patience: Duration = .seconds(5),
        _ round: @escaping @Sendable () async -> Void,
        background: @escaping @Sendable (SendableBox<Bool>) async -> Void
    ) async -> Bool {
        let stop = SendableBox(false)
        let rounds = SendableBox(0)
        let worker = Task {
            while !stop.value {
                await round()
                rounds.mutate { $0 += 1 }
            }
        }
        let other = Task { await background(stop) }
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: duration)
        var last = -1
        var lastProgress = clock.now
        var stalled = false
        // Done once `duration` has passed and progress was seen after it: a
        // deadlock that began late in the run is still caught.
        while true {
            try? await clock.sleep(for: .milliseconds(50))
            let now = rounds.value
            if now != last {
                last = now
                lastProgress = clock.now
                if clock.now >= end { break }
            } else if lastProgress.duration(to: clock.now) >= patience {
                stalled = true
                break
            }
        }
        stop.mutate { $0 = true }
        _ = (worker, other)
        return !stalled
    }

    /// Regression: resuming a receiver while holding the channel's lock
    /// deadlocked against that receiver's cancellation handler within a
    /// second, every run.
    @Test(.timeLimit(.minutes(1))) func receiversCancelledMidDeliveryNeverDeadlock() async {
        let channel = Channel<Int>(capacity: 1, label: "race")
        let ok = await runsWithoutStalling(for: .seconds(2), {
            let consumer = Task { _ = await channel.receive() }
            for _ in 0..<Int.random(in: 0...50) { await Task.yield() }
            consumer.cancel()
            await consumer.value
        }, background: { stop in
            var value = 0
            while !stop.value {
                value += 1
                try? await channel.send(value)
            }
        })
        #expect(ok, "no progress: a delivery deadlocked against a cancellation")
        channel.finish()
    }

    @Test(.timeLimit(.minutes(1))) func sendersCancelledMidHandOffNeverDeadlock() async {
        let channel = Channel<Int>(capacity: 1, label: "race")
        let ok = await runsWithoutStalling(for: .seconds(2), {
            let sender = Task { try? await channel.send(1) }
            for _ in 0..<Int.random(in: 0...50) { await Task.yield() }
            sender.cancel()
            await sender.value
        }, background: { stop in
            while !stop.value {
                if await channel.receive() == nil { await Task.yield() }
            }
        })
        #expect(ok, "no progress: a hand-off deadlocked against a cancellation")
        channel.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func everyElementArrivesExactlyOnceUnderCancellation() async throws {
        let channel = Channel<Int>(capacity: 4, label: "exactly-once")
        let received = SendableBox<[Int]>([])
        let sentOK = SendableBox<[Int]>([])
        let consumers = (0..<4).map { _ in
            Task {
                while let value = await channel.receive() { received.mutate { $0.append(value) } }
            }
        }
        await withTaskGroup { group in
            for producer in 0..<4 {
                group.addTask {
                    for index in 0..<400 {
                        let value = producer * 10_000 + index
                        let sender = Task { try await channel.send(value) }
                        if index % 7 == 0 { sender.cancel() }
                        if (try? await sender.value) != nil { sentOK.mutate { $0.append(value) } }
                    }
                }
            }
        }
        channel.finish()
        for consumer in consumers { await consumer.value }
        #expect(received.value.sorted() == sentOK.value.sorted(), "every successful send is received exactly once")
    }
}
