@testable import Stoic
import StoicTesting
import Testing

@Suite("Broadcast")
struct BroadcastTests {
    func drain(_ subscription: Broadcast<Int>.Subscription) async -> [Int] {
        var elements: [Int] = []
        for await element in subscription { elements.append(element) }
        return elements
    }

    @Test(.stoic(seed: 61), .timeLimit(.minutes(1)), .failureMode("design/20", "a `dropOldest` subscriber's buffer is full"))
    func dropOldestKeepsTheNewestElements() async throws {
        let broadcast = Broadcast<Int>(label: "progress")
        let latest = broadcast.subscribe(.dropOldest(2))
        let roomy = broadcast.subscribe(.dropOldest(10))
        for value in 1...5 { try await broadcast.publish(value) }
        broadcast.finish()
        #expect(await drain(latest) == [4, 5])
        #expect(await drain(roomy) == [1, 2, 3, 4, 5])
        #expect(latest.droppedCount == 3)
        #expect(roomy.droppedCount == 0)
        let drops = StoicTest.events.events(named: "channel.dropped")
        #expect(drops.count == 3)
        #expect(drops.allSatisfy { $0.label == "progress" && $0.text("policy") == "drop_oldest" })
    }

    @Test(.stoic(seed: 62), .timeLimit(.minutes(1)), .failureMode("design/20", "a `dropNewest` subscriber's buffer is full"))
    func dropNewestKeepsTheOldestElements() async throws {
        let broadcast = Broadcast<Int>(label: "log")
        let first = broadcast.subscribe(.dropNewest(2))
        for value in 1...5 { try await broadcast.publish(value) }
        broadcast.finish()
        #expect(await drain(first) == [1, 2])
        #expect(first.droppedCount == 3)
        #expect(StoicTest.events.events(named: "channel.dropped").allSatisfy { $0.text("policy") == "drop_newest" })
    }

    @Test(.stoic(seed: 63), .timeLimit(.minutes(1)), .failureMode("design/20", "a `suspend` subscriber's buffer is full"))
    func aFullSuspendSubscriberHoldsThePublisherAndThoseAfterIt() async throws {
        let broadcast = Broadcast<Int>(label: "backpressure")
        let slow = broadcast.subscribe(.suspend(1))
        let after = broadcast.subscribe(.dropOldest(10))
        try await broadcast.publish(1)
        let publisher = Task { try await broadcast.publish(2) }
        #expect(await holdsThroughout { after.bufferedCount == 1 })   // 2 has not got past `slow`
        var iterator = slow.makeAsyncIterator()
        #expect(await iterator.next() == 1)   // room opens
        try await publisher.value
        #expect(await iterator.next() == 2)
        #expect(after.bufferedCount == 2)
    }

    @Test(.stoic(seed: 64), .timeLimit(.minutes(1)), .failureMode("design/20", "a `suspend` subscriber ends while a publish waits for it"))
    func aSubscriberThatLeavesReleasesAWaitingPublish() async throws {
        let broadcast = Broadcast<Int>(label: "release")
        let slow = broadcast.subscribe(.suspend(1))
        let after = broadcast.subscribe(.dropOldest(10))
        try await broadcast.publish(1)
        let publisher = Task { try await broadcast.publish(2) }
        #expect(await holdsThroughout { after.bufferedCount == 1 })
        slow.cancel()
        try await publisher.value   // released, and went on to the rest
        #expect(after.bufferedCount == 2)
        #expect(broadcast.subscriberCount == 1)
    }

    @Test(.stoic(seed: 69), .timeLimit(.minutes(1)), .failureMode("design/20", "`finish()` is called while a publish waits for a subscriber"))
    func aPublishThatFinishCutsShortThrowsClosed() async throws {
        let broadcast = Broadcast<Int>(label: "cut-short")
        let slow = broadcast.subscribe(.suspend(1))
        let after = broadcast.subscribe(.dropOldest(10))
        try await broadcast.publish(1)
        let publisher = Task { () -> Rejection? in
            do throws(Rejection) { try await broadcast.publish(2); return nil } catch { return error }
        }
        #expect(await holdsThroughout { after.bufferedCount == 1 })   // held up at `slow`
        broadcast.finish()
        // `slow` never got it. (Whether `after` did depends on whether the
        // released publish reaches it before `finish()` does.)
        #expect(await publisher.value?.reason == .closed, "previously returned as if delivered")
        #expect(slow.bufferedCount == 1)
    }

    @Test(.stoic(seed: 65), .timeLimit(.minutes(1)), .failureMode("design/20", "the publisher is cancelled while it waits for a subscriber"))
    func aCancelledPublishHasReachedOnlyTheEarlierSubscribers() async throws {
        let broadcast = Broadcast<Int>(label: "cancelled")
        let early = broadcast.subscribe(.dropOldest(10))
        let slow = broadcast.subscribe(.suspend(1))
        let late = broadcast.subscribe(.dropOldest(10))
        try await broadcast.publish(1)
        let publisher = Task { () -> Rejection? in
            do throws(Rejection) { try await broadcast.publish(2); return nil } catch { return error }
        }
        #expect(await eventually { early.bufferedCount == 2 })
        publisher.cancel()
        #expect(await publisher.value?.reason == .cancelled)
        #expect(late.bufferedCount == 1)
        #expect(slow.bufferedCount == 1)
    }

    @Test(.stoic(seed: 66), .timeLimit(.minutes(1)), .failureMode("design/20", "a subscriber's task is cancelled"))
    func cancellingTheConsumerEndsTheLoopAndRemovesTheSubscriber() async throws {
        let broadcast = Broadcast<Int>(label: "consumer")
        let subscription = broadcast.subscribe(.suspend(1))
        let consumer = Task { await drain(subscription) }
        #expect(await eventually { broadcast.subscriberCount == 1 })
        try await broadcast.publish(1)
        consumer.cancel()
        _ = await consumer.value
        #expect(broadcast.subscriberCount == 0)
        // Nobody is left to hold a publisher up.
        for value in 2...4 { try await broadcast.publish(value) }
    }

    @Test(.stoic(seed: 67), .timeLimit(.minutes(1)), .failureMode("design/20", "a subscription is dropped without being iterated"))
    func aDroppedSubscriptionLeavesTheBroadcast() async throws {
        let broadcast = Broadcast<Int>(label: "dropped")
        func subscribeAndForget() { _ = broadcast.subscribe(.suspend(1)) }
        subscribeAndForget()
        #expect(broadcast.subscriberCount == 0)
        for value in 1...3 { try await broadcast.publish(value) }   // would hang on a full buffer
    }

    @Test(.stoic(seed: 68), .timeLimit(.minutes(1)), .failureMode("design/20", "`finish()` is called"))
    func finishLetsSubscribersDrainThenEnds() async {
        let broadcast = Broadcast<Int>(label: "finish")
        let subscription = broadcast.subscribe(.dropOldest(4))
        try? await broadcast.publish(1)
        try? await broadcast.publish(2)
        broadcast.finish()
        #expect(await drain(subscription) == [1, 2])
        #expect(broadcast.subscriberCount == 0)
        do throws(Rejection) {
            try await broadcast.publish(3)
            Issue.record("a finished broadcast accepted an element")
        } catch {
            #expect(error.reason == .closed)
        }
        #expect(await drain(broadcast.subscribe(.suspend(1))) == [])
    }
}
