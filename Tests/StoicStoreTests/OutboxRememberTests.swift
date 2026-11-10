import Stoic
@testable import StoicStore
import StoicTesting
import Testing

/// design/15: an outbox opened with `rememberSettled` keeps the keys of the
/// last entries to settle, so enqueueing one of them again writes nothing.
@Suite("Outbox: remembered settled keys")
struct OutboxRememberTests {
    static let path = "/d/outbox"

    func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    func open(
        _ disk: SimulatedFileSystem, remember: Int = 8, threshold: Int = 64 * 1024,
        policy: DeliveryPolicy = DeliveryPolicy(schedule: .immediate.attempts(1))
    ) throws -> Outbox<String> {
        try Outbox<String>.open(
            at: Self.path, codec: .utf8, fileSystem: disk, policy: policy, compactionThreshold: threshold,
            rememberSettled: remember)
    }

    func deliverAll(_ outbox: Outbox<String>) async throws {
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in .delivered }
        }
    }

    @Test(.failureMode("design/15", "an outbox that remembers is asked to enqueue a key it delivered"))
    func aDeliveredKeyIsNotEnqueuedAgain() async throws {
        let events = RecordingInstrumentation()
        let disk = try disk()
        try await withTestAmbient(clock: ImmediateClock(), events: events) {
            let outbox = try open(disk)
            let key = IdempotencyKey(rawValue: "k1")
            try await outbox.enqueue("A", key: key)
            try await deliverAll(outbox)
            #expect(await outbox.isSettled(key))
            let operations = disk.operationCount
            #expect(try await outbox.enqueue("A", key: key) == key)
            #expect(disk.operationCount == operations, "nothing is written")
            #expect(await outbox.pendingCount == 0)
            let delivered = SendableBox(0)
            _ = try await outbox.deliverPending { _ in delivered.mutate { $0 += 1 }; return .delivered }
            #expect(delivered.value == 0, "nothing is sent")
            guard case .notPending = try await outbox.deliver(key, using: { _ in .delivered }) else {
                Issue.record("a settled key was delivered")
                return
            }
        }
        let settled = try #require(events.events(named: "store.outbox_already_settled").first)
        #expect(settled.level == .info)
    }

    @Test(.failureMode("design/15", "an outbox that remembers is asked to enqueue a key it discarded"))
    func aDiscardedOrExpiredKeyIsNotEnqueuedAgain() async throws {
        let disk = try disk()
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            var policy = DeliveryPolicy(schedule: .immediate.attempts(1))
            policy.expiry = .init(maxAge: .seconds(60))
            let outbox = try open(disk, policy: policy)
            let byHand = IdempotencyKey(rawValue: "by-hand"), refused = IdempotencyKey(rawValue: "refused")
            let expired = IdempotencyKey(rawValue: "expired")
            try await outbox.enqueue("A", key: byHand)
            try await outbox.enqueue("B", key: refused)
            try await outbox.discard(byHand)
            _ = try await outbox.deliverPending { _ in .discard(reason: "http 422") }
            try await outbox.enqueue("C", key: expired)
            await clock.advance(by: .seconds(61))
            _ = try await outbox.deliverPending { _ in .delivered }
            for key in [byHand, refused, expired] {
                #expect(await outbox.isSettled(key), "\(key)")
                try await outbox.enqueue("again", key: key)
            }
            #expect(await outbox.pendingCount == 0, "an expired effect is never sent late")
        }
    }

    @Test(.failureMode("design/15", "an outbox that remembers is relaunched or compacted"))
    func rememberedKeysSurviveRelaunchAndCompaction() async throws {
        let disk = try disk()
        var outbox = try open(disk, threshold: 1)
        let keys = (0..<4).map { IdempotencyKey(rawValue: "k\($0)") }
        for key in keys { try await outbox.enqueue("x", key: key) }
        try await deliverAll(outbox)   // compacts afterwards: the log is past one byte
        try await outbox.enqueue("y", key: IdempotencyKey(rawValue: "pending"))
        try await outbox.close()
        // Relaunch: the snapshot carries the four, the log the pending one.
        outbox = try open(disk, threshold: 1)
        for key in keys { #expect(await outbox.isSettled(key)) }
        #expect(await outbox.pendingKeys == [IdempotencyKey(rawValue: "pending")])
        // Relaunch again after a delivery whose acknowledgement is only in the log.
        try await outbox.close()
        outbox = try open(disk, threshold: 64 * 1024)
        try await deliverAll(outbox)
        try await outbox.close()
        outbox = try open(disk)
        #expect(await outbox.isSettled(IdempotencyKey(rawValue: "pending")))
        for key in keys { #expect(await outbox.isSettled(key)) }
        try await outbox.close()
    }

    @Test(.failureMode("design/15", "more keys settle than the outbox remembers"))
    func theOldestKeysAreForgottenFirst() async throws {
        let disk = try disk()
        var outbox = try open(disk, remember: 2)
        let keys = (0..<3).map { IdempotencyKey(rawValue: "k\($0)") }
        for key in keys { try await outbox.enqueue("x", key: key) }
        try await deliverAll(outbox)
        #expect(await outbox.isSettled(keys[0]) == false)
        #expect(await outbox.isSettled(keys[1]))
        #expect(await outbox.isSettled(keys[2]))
        // Forgotten: enqueued again, it is a new entry, delivered under the same key.
        try await outbox.enqueue("x", key: keys[0])
        #expect(await outbox.pendingKeys == [keys[0]])
        try await outbox.close()
        outbox = try open(disk, remember: 2)
        #expect(await outbox.pendingKeys == [keys[0]], "a key enqueued again after it was forgotten is pending after relaunch")
        #expect(await outbox.isSettled(keys[0]) == false)
        try await outbox.close()
    }

    /// The window stays bounded however many settle, and order holds across
    /// the squeezes that keep it so.
    @Test func theWindowIsBoundedAndOrdered() {
        var window = Outbox<String>.SettledKeys(capacity: 100)
        for index in 0..<10_000 { window.add(IdempotencyKey(rawValue: "k\(index)")) }
        #expect(window.keys == (9_900..<10_000).map { IdempotencyKey(rawValue: "k\($0)") })
        window.remove(IdempotencyKey(rawValue: "k9950"))
        window.add(IdempotencyKey(rawValue: "k9950"))
        #expect(window.keys.last == IdempotencyKey(rawValue: "k9950"))
        #expect(window.keys.count == 100)
    }

    @Test(.failureMode("design/15", "an outbox does not remember (`rememberSettled: 0`)"))
    func anOutboxThatDoesNotRememberWritesWhatEarlierReleasesRead() async throws {
        let disk = try disk()
        let outbox = try Outbox<String>.open(at: Self.path, codec: .utf8, fileSystem: disk, compactionThreshold: 1)
        try await outbox.enqueue("A", key: IdempotencyKey(rawValue: "k1"))
        try await outbox.enqueue("B", key: IdempotencyKey(rawValue: "k2"))
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliver(IdempotencyKey(rawValue: "k1")) { _ in .delivered }
        }
        #expect(await outbox.isSettled(IdempotencyKey(rawValue: "k1")) == false)
        try await outbox.close()
        let snapshot = try #require(try Journal.open(at: Self.path, fileSystem: disk).replay().snapshot)
        // Exactly the 0.5.0 layout: count 1, the entry, nothing after.
        #expect(snapshot.bytes == littleEndian(UInt32(1)) + littleEndian(UInt64(2)) + [2] + bytes("k2") + littleEndian(UInt32(1)) + bytes("B"))
        #expect(try Self.releasedDecodeSnapshot(snapshot.bytes, path: Self.path).map(\.key) == [IdempotencyKey(rawValue: "k2")])
    }

    @Test(.failureMode("design/15", "an older build opens an outbox whose snapshot remembers settled keys"))
    func anOlderBuildRefusesARememberingSnapshotCleanly() async throws {
        for pending in [0, 2] {
            let disk = try disk()
            let outbox = try open(disk, threshold: 1)
            for index in 0..<3 { try await outbox.enqueue("x\(index)", key: IdempotencyKey(rawValue: "k\(index)")) }
            _ = try await withTestAmbient(clock: ImmediateClock()) {
                try await outbox.deliver(IdempotencyKey(rawValue: "k0")) { _ in .delivered }
            }
            if pending == 0 { try await deliverAll(outbox) }
            try await outbox.close()
            let journal = try Journal.open(at: Self.path, fileSystem: disk)
            let snapshot = try #require(try journal.replay().snapshot)
            try journal.close()
            let header: UInt32 = readLittleEndian(snapshot.bytes, at: 0)
            #expect(header & 0x4000_0000 != 0, "flagged")
            do {
                _ = try Self.releasedDecodeSnapshot(snapshot.bytes, path: Self.path)
                Issue.record("a release before this one read a remembering snapshot")
            } catch {
                #expect(error.kind == .corrupt && error.operation == "outbox snapshot")
            }
        }
    }

    /// `Outbox.decodeSnapshot` exactly as release 0.5.0 shipped it
    /// (`git show 0.5.0:Sources/StoicStore/Outbox.swift`): what an older build
    /// does with a snapshot.
    static func releasedDecodeSnapshot(_ bytes: [UInt8], path: String) throws(StoreError) -> [Outbox<String>.Stored] {
        typealias Stored = Outbox<String>.Stored
        let stampedFlag: UInt32 = 0x8000_0000
        func corrupt() -> StoreError {
            StoreError(kind: .corrupt, operation: "outbox snapshot", path: path, detail: "malformed")
        }
        guard bytes.count >= 4 else { throw corrupt() }
        let header = readLittleEndian(bytes, at: 0) as UInt32
        let stamped = header & stampedFlag != 0
        let count = Int(header & ~stampedFlag)
        var offset = 4
        var entries: [Stored] = []
        for _ in 0..<count {
            guard bytes.count >= offset + (stamped ? 17 : 9) else { throw corrupt() }
            let sequence: UInt64 = readLittleEndian(bytes, at: offset)
            offset += 8
            var enqueuedAt: Int64?
            if stamped {
                let stamp = Int64(bitPattern: readLittleEndian(bytes, at: offset) as UInt64)
                enqueuedAt = stamp == .min ? nil : stamp
                offset += 8
            }
            let keyLength = Int(bytes[offset])
            offset += 1
            guard bytes.count >= offset + keyLength + 4 else { throw corrupt() }
            let key = IdempotencyKey(rawValue: String(decoding: bytes[offset..<offset + keyLength], as: UTF8.self))
            offset += keyLength
            let length = Int(readLittleEndian(bytes, at: offset) as UInt32)
            offset += 4
            guard bytes.count >= offset + length else { throw corrupt() }
            entries.append(Stored(key: key, sequence: sequence, bytes: Array(bytes[offset..<offset + length]), enqueuedAt: enqueuedAt))
            offset += length
        }
        guard offset == bytes.count else { throw corrupt() }
        return entries
    }
}

/// design/15's crash invariants, run again on an outbox that remembers: and
/// one more, that no acknowledged key is ever enqueued again.
@Suite("Outbox crash consistency, remembering")
struct OutboxRememberCrashTests {
    static let keys = OutboxCrashTests.keys

    static func open(_ disk: SimulatedFileSystem, threshold: Int) throws -> Outbox<String> {
        try Outbox<String>.open(
            at: OutboxCrashTests.path, codec: .utf8, fileSystem: disk,
            policy: DeliveryPolicy(schedule: .immediate.attempts(2)), compactionThreshold: threshold, rememberSettled: 8)
    }

    @Test(.failureMode("design/15", "an outbox that remembers dies at any point"), arguments: [64 * 1024, 1])
    func noAcknowledgedKeyComesBackAfterAnyCrash(threshold: Int) async throws {
        let report = try await exploreCrashes(
            "remembering outbox threshold=\(threshold)",
            samples: 12,
            setup: { try $0.createDirectory("/d") },
            operation: { disk in
                let outbox = try Self.open(disk, threshold: threshold)
                for (index, item) in OutboxCrashTests.items.enumerated() {
                    try await outbox.enqueue(item, key: Self.keys[index])
                    disk.checkpoint("enq:\(index + 1)")
                }
                let delivered = SendableBox(0)
                _ = try await withTestAmbient(clock: ImmediateClock()) {
                    try await outbox.deliverPending { _ in
                        let count = delivered.value
                        if count > 0 { disk.checkpoint("acked:\(count)") }
                        delivered.mutate { $0 += 1 }
                        disk.checkpoint("delivered:\(count + 1)")
                        return .delivered
                    }
                }
                disk.checkpoint("acked:\(delivered.value)")
                try await outbox.close()
            },
            recovery: { disk in _ = try await Self.open(disk, threshold: threshold).entries() },
            check: { disk, context in
                // design/15's own invariants hold for an outbox that remembers…
                let opened = try Self.open(disk, threshold: threshold)
                let acknowledged = OutboxCrashTests.reached(context, "acked:")
                // …and an acknowledged key is remembered: enqueued again, it is not pending.
                for index in 0..<acknowledged {
                    guard await opened.isSettled(Self.keys[index]) else { return "acknowledged key \(index) was forgotten" }
                    try await opened.enqueue("again", key: Self.keys[index])
                    if await opened.pendingKeys.contains(Self.keys[index]) { return "acknowledged key \(index) was enqueued again" }
                }
                try await opened.close()
                return try await OutboxCrashTests.invariant(threshold: threshold)(disk, context)
            }
        )
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.crashPoints >= 8)
    }
}
