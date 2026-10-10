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
