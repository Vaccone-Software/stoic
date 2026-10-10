import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

struct Message: Codable, Sendable, Equatable {
    var id: Int
    var text: String
}

/// An error that classifies itself as permanent, like an HTTP 400.
struct Rejected: Error, Retryable {
    var retryDecision: RetryDecision { .stop }
}

struct Unavailable: Error, Retryable {
    var retryDecision: RetryDecision { .retry }
}

@Suite("Outbox")
struct OutboxTests {
    func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    func open(
        _ disk: SimulatedFileSystem,
        policy: DeliveryPolicy = DeliveryPolicy(schedule: .fixed(.seconds(1)).attempts(3)),
        threshold: Int = 64 * 1024
    ) throws -> Outbox<String> {
        try Outbox<String>.open(at: "/d/outbox", codec: .utf8, fileSystem: disk, policy: policy, compactionThreshold: threshold)
    }

    @Test func enqueuedItemsSurviveARelaunchInOrder() async throws {
        let disk = try disk()
        var outbox = try open(disk)
        let first = try await outbox.enqueue("one")
        let second = try await outbox.enqueue("two")
        #expect(first != second)
        try await outbox.close()
        outbox = try open(disk)
        #expect(await outbox.pendingKeys == [first, second])
        #expect(try await outbox.entries().map(\.item) == ["one", "two"])
    }

    @Test func enqueueIsDurableBeforeItReturns() async throws {
        let disk = try disk()
        let outbox = try open(disk)
        try await outbox.enqueue("one")
        disk.crash()
        let reopened = try open(disk)
        #expect(try await reopened.entries().map(\.item) == ["one"])
    }

    @Test func enqueueingTheSameKeyTwiceQueuesOnce() async throws {
        let outbox = try open(try disk())
        let key = IdempotencyKey(rawValue: "order-1234")
        #expect(try await outbox.enqueue("a", key: key) == key)
        #expect(try await outbox.enqueue("a again", key: key) == key)
        #expect(try await outbox.entries().map(\.item) == ["a"])
    }

    @Test func deliveryRunsInOrderAndAcknowledgesEachEntry() async throws {
        let disk = try disk()
        let outbox = try open(disk)
        let keys = [try await outbox.enqueue("a"), try await outbox.enqueue("b"), try await outbox.enqueue("c")]
        let seen = SendableBox<[String]>([])
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in seen.mutate { $0.append(entry.item) } }
        }
        #expect(seen.value == ["a", "b", "c"])
        #expect(report.delivered == keys)
        #expect(report.failed.isEmpty)
        #expect(report.remaining == 0)
        #expect(await outbox.pendingCount == 0)
        // And durably so: a relaunch has nothing to redeliver.
        disk.crash()
        #expect(await (try open(disk)).pendingCount == 0)
    }

    @Test func theSameKeyTravelsWithEveryAttempt() async throws {
        let outbox = try open(try disk())
        let key = try await outbox.enqueue("payload")
        let sent = SendableBox<[String]>([])
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in
                sent.mutate { $0.append(entry.key.rawValue) }
                if sent.value.count < 3 { throw Unavailable() }
            }
        }
        #expect(sent.value == [key.rawValue, key.rawValue, key.rawValue])
        #expect(report.delivered == [key])
    }

    @Test func retriesFollowTheBoundedSchedule() async throws {
        let outbox = try open(try disk(), policy: DeliveryPolicy(schedule: .delays([.seconds(1), .seconds(5)])))
        try await outbox.enqueue("x")
        let clock = ImmediateClock()
        let attempts = SendableBox(0)
        let report = try await withTestAmbient(clock: clock) {
            try await outbox.deliverPending { _ in
                attempts.mutate { $0 += 1 }
                throw Unavailable()
            }
        }
        #expect(attempts.value == 3)   // the first try and two retries, then it gives up
        #expect(clock.sleeps == [.seconds(1), .seconds(5)])
        #expect(report.failed.map(\.attempts) == [3])
        #expect(report.remaining == 1)
        #expect(await outbox.pendingCount == 1)
    }

    @Test func aPermanentFailureIsNotRetriedAndStopsTheRun() async throws {
        let outbox = try open(try disk())
        try await outbox.enqueue("bad")
        try await outbox.enqueue("good")
        let attempts = SendableBox<[String]>([])
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in
                attempts.mutate { $0.append(entry.item) }
                if entry.item == "bad" { throw Rejected() }
            }
        }
        #expect(attempts.value == ["bad"])   // one attempt, and "good" did not overtake it
        #expect(report.failed.count == 1)
        #expect(report.delivered.isEmpty)
        #expect(await outbox.pendingCount == 2)
    }

    @Test func independentEntriesCanContinuePastAFailure() async throws {
        let outbox = try open(try disk(), policy: DeliveryPolicy(schedule: .immediate.attempts(2), onFailure: .continueWithNext))
        try await outbox.enqueue("bad")
        try await outbox.enqueue("good")
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in
                if entry.item == "bad" { throw Unavailable() }
            }
        }
        #expect(report.failed.count == 1)
        #expect(report.delivered.count == 1)
        #expect(try await outbox.entries().map(\.item) == ["bad"])
    }

    @Test func failedEntriesAreDeliveredOnTheNextRunAfterARelaunch() async throws {
        let disk = try disk()
        var outbox = try open(disk)
        try await outbox.enqueue("a")
        try await outbox.enqueue("b")
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in throw Unavailable() }
        }
        try await outbox.close()
        outbox = try open(disk)
        let seen = SendableBox<[String]>([])
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in seen.mutate { $0.append(entry.item) } }
        }
        #expect(seen.value == ["a", "b"])
        #expect(report.remaining == 0)
    }

    @Test func anEntryDeliveredButNeverAcknowledgedIsDeliveredAgainWithTheSameKey() async throws {
        // At-least-once: the app dies after the server accepted the entry and
        // before the acknowledgement was durable.
        let disk = try disk()
        var outbox = try open(disk)
        let key = try await outbox.enqueue("a")
        let sent = SendableBox<[String]>([])
        disk.inject(5, on: .write)   // the acknowledgement's write fails
        await #expect(throws: StoreError.self) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await outbox.deliverPending { entry in sent.mutate { $0.append(entry.key.rawValue) } }
            }
        }
        try await outbox.close()
        outbox = try open(disk)
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in sent.mutate { $0.append(entry.key.rawValue) } }
        }
        #expect(sent.value == [key.rawValue, key.rawValue])
    }

    @Test func aSecondRunWhileOneIsInProgressDoesNothing() async throws {
        let outbox = try open(try disk())
        try await outbox.enqueue("a")
        let started = TestGate()
        let release = TestGate()
        let first = Task {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await outbox.deliverPending { _ in
                    started.open()
                    await release.wait()
                }
            }
        }
        await started.wait()
        let second = try await outbox.deliverPending { _ in Issue.record("delivered twice at once") }
        #expect(second.wasAlreadyRunning)
        #expect(second.remaining == 1)
        release.open()
        #expect(try await first.value.delivered.count == 1)
    }

    @Test func cancellationLeavesTheEntryInFlightPending() async throws {
        let outbox = try open(try disk())
        try await outbox.enqueue("a")
        let started = TestGate()
        let run = Task {
            try await outbox.deliverPending { _ in
                started.open()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await started.wait()
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(await outbox.pendingCount == 1)
    }

    @Test func discardDropsAnEntryDurably() async throws {
        let disk = try disk()
        let outbox = try open(disk)
        let key = try await outbox.enqueue("poison")
        try await outbox.enqueue("fine")
        try await outbox.discard(key)
        disk.crash()
        #expect(try await open(disk).entries().map(\.item) == ["fine"])
    }

    @Test func compactionBoundsTheLogAndLosesNothing() async throws {
        let disk = try disk()
        var outbox = try open(disk, threshold: 200)
        for index in 0..<20 { try await outbox.enqueue("message \(index)") }
        let seen = SendableBox(0)
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in
                seen.mutate { $0 += 1 }
                if seen.value > 15 { throw Rejected() }   // 15 delivered, then a permanent failure
            }
        }
        #expect(await outbox.pendingCount == 5)
        #expect(disk.contents(of: "/d/outbox.snapshot") != nil)   // compacted: the log no longer holds 20 enqueues
        try await outbox.close()
        outbox = try open(disk, threshold: 200)
        #expect(try await outbox.entries().map(\.item) == (15..<20).map { "message \($0)" })
        let key = try await outbox.enqueue("after")   // numbering continues
        #expect(await outbox.pendingKeys.last == key)
    }

    @Test func anItemThatNoLongerDecodesIsReportedAndCanBeDiscarded() async throws {
        let disk = try disk()
        let writer = try Outbox<Message>.open(at: "/d/m", codec: .json(), fileSystem: disk)
        let key = try await writer.enqueue(Message(id: 1, text: "hi"))
        try await writer.close()
        // The app changes the type; old entries no longer decode.
        struct Changed: Codable, Sendable { var uuid: String }
        let reader = try Outbox<Changed>.open(
            at: "/d/m", codec: .json(), fileSystem: disk,
            policy: DeliveryPolicy(schedule: .immediate.attempts(2), onFailure: .continueWithNext)
        )
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await reader.deliverPending { _ in Issue.record("should not decode") }
        }
        #expect(report.failed.map(\.key) == [key])
        #expect((report.failed.first?.error as? StoreError)?.kind == .corrupt)
        #expect(report.failed.first?.attempts == 0)
        try await reader.discard(key)
        #expect(await reader.pendingCount == 0)
    }

    @Test func jsonItemsRoundTripOnTheRealFileSystem() async throws {
        let dir = try TempDirectory()
        var outbox = try Outbox<Message>.open(at: dir.file("outbox"), codec: .json())
        try await outbox.enqueue(Message(id: 1, text: "héllo"))
        try await outbox.enqueue(Message(id: 2, text: "wörld"))
        try await outbox.close()
        outbox = try Outbox<Message>.open(at: dir.file("outbox"), codec: .json())
        let seen = SendableBox<[Message]>([])
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in seen.mutate { $0.append(entry.item) } }
        }
        #expect(seen.value == [Message(id: 1, text: "héllo"), Message(id: 2, text: "wörld")])
    }

    @Test func anItemThatCannotBeEncodedIsRefusedBeforeAnythingIsWritten() async throws {
        let disk = try disk()
        let outbox = try Outbox<Int>.open(
            at: "/d/o", codec: OutboxCodec(encode: { _ in throw Rejected() }, decode: { _ in 0 }), fileSystem: disk
        )
        let before = disk.operationCount
        await #expect(throws: StoreError.self) { try await outbox.enqueue(1) }
        #expect(disk.operationCount == before)
    }

    @Test func deliveryDecisionsAreReportedAsEvents() async throws {
        let events = RecordingInstrumentation()
        let outbox = try open(try disk(), policy: DeliveryPolicy(schedule: .immediate.attempts(2)))
        try await outbox.enqueue("ok")
        try await outbox.enqueue("nope")
        try await withTestAmbient(clock: ImmediateClock(), events: events) {
            _ = try await outbox.deliverPending { entry in if entry.item == "nope" { throw Rejected() } }
        }
        #expect(events.names.filter { $0.rawValue.hasPrefix("store.") } == ["store.outbox_delivered", "store.outbox_delivery_failed"])
    }

    // MARK: Opening a long outbox

    /// A journal holding `pending + acknowledged` enqueues and `acknowledged`
    /// acknowledgements (every fifth entry), written as the outbox would.
    func writeLongOutbox(_ disk: SimulatedFileSystem, pending: Int, acknowledged: Int) throws {
        let journal = try Journal.open(at: "/d/outbox", fileSystem: disk)
        let total = pending + acknowledged
        let step = max(1, total / max(1, acknowledged))
        var records: [[UInt8]] = []
        var acknowledgements = 0
        for index in 0..<total {
            let key = IdempotencyKey(rawValue: "key-\(index)")
            records.append(try Outbox<String>.enqueueRecord(key: key, item: Array("item \(index)".utf8)))
            if index % step == 0, acknowledgements < acknowledged {
                records.append(try Outbox<String>.acknowledgeRecord(key: key))
                acknowledgements += 1
            }
        }
        try journal.append(batch: records)
        try journal.close()
    }

    func timeToOpen(pending: Int, acknowledged: Int) async throws -> Duration {
        let disk = SimulatedFileSystem(recordsHistory: false)
        try disk.createDirectory("/d")
        try writeLongOutbox(disk, pending: pending, acknowledged: acknowledged)
        let clock = ContinuousClock()
        let start = clock.now
        let outbox = try open(disk)
        let elapsed = clock.now - start
        #expect(await outbox.pendingCount == pending)
        return elapsed
    }

    @Test func openingTwentyThousandPendingEntriesIsFast() async throws {
        let elapsed = try await timeToOpen(pending: 20_000, acknowledged: 4_000)
        // Quadratic, this took 17 seconds (and 1.1 s at 5,000). The bound is
        // generous for a slow, loaded machine and a debug build; it still
        // fails by an order of magnitude on a quadratic open.
        #expect(elapsed < .seconds(3), "opened 20,000 pending entries in \(elapsed)")
    }

    @Test func theTimeToOpenGrowsLinearlyNotQuadratically() async throws {
        let small = try await timeToOpen(pending: 5_000, acknowledged: 1_000)
        let large = try await timeToOpen(pending: 20_000, acknowledged: 4_000)
        // Four times the entries: about four times the time when linear,
        // sixteen when quadratic. The floor keeps timer noise on a small
        // run from making the ratio meaningless.
        let floor = Duration.milliseconds(20)
        #expect(large < max(small, floor) * 10, "5,000 entries took \(small), 20,000 took \(large)")
    }
}
