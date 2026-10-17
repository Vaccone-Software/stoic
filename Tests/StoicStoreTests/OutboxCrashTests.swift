import Stoic
@testable import StoicStore
import StoicTesting
import Testing

@Suite("Outbox crash consistency")
struct OutboxCrashTests {
    static let items = ["A", "B", "C"]
    static let keys = items.indices.map { IdempotencyKey(rawValue: "key-\($0)") }
    static let path = "/d/outbox"

    static func open(_ disk: SimulatedFileSystem, threshold: Int) throws -> Outbox<String> {
        try Outbox<String>.open(
            at: path, codec: .utf8, fileSystem: disk,
            policy: DeliveryPolicy(schedule: .immediate.attempts(2)), compactionThreshold: threshold
        )
    }

    /// Enqueues A, B, C; then delivers them. With `failing`, the entry with
    /// that item is rejected permanently, so the run stops there.
    static func run(_ disk: SimulatedFileSystem, threshold: Int, failing: String? = nil) async throws {
        let outbox = try open(disk, threshold: threshold)
        for (index, item) in items.enumerated() {
            try await outbox.enqueue(item, key: keys[index])
            disk.checkpoint("enq:\(index + 1)")
        }
        let delivered = SendableBox(0)
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in
                let count = delivered.value
                if count > 0 { disk.checkpoint("acked:\(count)") }   // the previous entry's ack has returned
                if entry.item == failing { throw Rejected() }
                delivered.mutate { $0 += 1 }
                disk.checkpoint("delivered:\(count + 1)")
                return .delivered
            }
        }
        disk.checkpoint("acked:\(delivered.value)")
        try await outbox.close()
    }

    static func reached(_ context: CrashContext, _ prefix: String) -> Int {
        context.checkpointsReached(prefix: prefix).compactMap { Int($0.dropFirst(prefix.count)) }.max() ?? 0
    }

    /// The at-least-once invariant at one crash point.
    static func invariant(threshold: Int) -> (SimulatedFileSystem, CrashContext) async throws -> String? {
        { disk, context in
            let outbox = try open(disk, threshold: threshold)
            let recovered = try await outbox.entries()
            let enqueued = reached(context, "enq:")
            let deliveryStarted = reached(context, "delivered:")
            let acknowledged = reached(context, "acked:")

            // 1. What is pending is a subsequence of what was enqueued, in order, intact.
            var cursor = 0
            for entry in recovered {
                guard let index = keys.indices.dropFirst(cursor).first(where: { keys[$0] == entry.key }) else {
                    return "pending entry \(entry.key) is unknown or out of order (pending: \(recovered.map(\.key)))"
                }
                guard entry.item == items[index] else { return "entry \(entry.key) came back as \(entry.item), not \(items[index])" }
                cursor = index + 1
            }
            let present = Set(recovered.map(\.key))
            // 2. No entry is lost: an enqueued entry whose delivery had not even
            //    finished (so its acknowledgement cannot have been written) is pending.
            for index in 0..<enqueued where index >= deliveryStarted && !present.contains(keys[index]) {
                return "entry \(index) (\(items[index])) was enqueued and never delivered, but is gone"
            }
            // 3. Acknowledged entries are not redelivered.
            for index in 0..<acknowledged where present.contains(keys[index]) {
                return "entry \(index) (\(items[index])) was acknowledged durable but is pending again"
            }
            // 4. The recovered outbox works: it delivers exactly what is pending, in order, then takes more.
            let seen = SendableBox<[String]>([])
            let report = try await withTestAmbient(clock: ImmediateClock()) {
                try await outbox.deliverPending { entry in seen.mutate { $0.append(entry.item) }; return .delivered }
            }
            guard seen.value == recovered.map(\.item), report.remaining == 0 else {
                return "after recovery, delivery sent \(seen.value) for pending \(recovered.map(\.item)), \(report.remaining) remaining"
            }
            try await outbox.enqueue("Z")
            guard try await outbox.entries().map(\.item) == ["Z"] else { return "an outbox could not be enqueued to after recovery" }
            return nil
        }
    }

    @Test(.failureMode("design/15", "it dies after the ack returned"), arguments: [64 * 1024, 1], [nil, "B", "A"] as [String?])
    func noEntryIsLostAndNoAcknowledgedEntryComesBack(threshold: Int, failing: String?) async throws {
        let report = try await exploreCrashes(
            "Outbox threshold=\(threshold) failing=\(failing ?? "none")",
            samples: 12,
            setup: { try $0.createDirectory("/d") },
            operation: { try await Self.run($0, threshold: threshold, failing: failing) },
            recovery: { disk in _ = try await Self.open(disk, threshold: threshold).entries() },
            check: Self.invariant(threshold: threshold)
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.crashPoints >= 8)
    }

    @Test func anOutboxThatAcknowledgesBeforeTheEntryIsDeliveredLosesIt() async throws {
        // A broken delivery order: acknowledge first, send after. A crash
        // between the acknowledgement and the send loses the entry; the
        // checkpoint for "the send happened" comes after the acknowledgement,
        // and the check says an entry whose send was not reported must remain.
        let report = try await exploreCrashes(
            "outbox acknowledging before delivering",
            samples: 8,
            setup: { try $0.createDirectory("/d") },
            operation: { disk in
                let outbox = try Self.open(disk, threshold: 64 * 1024)
                for (index, item) in Self.items.enumerated() {
                    try await outbox.enqueue(item, key: Self.keys[index])
                    disk.checkpoint("enq:\(index + 1)")
                }
                for (index, key) in Self.keys.enumerated() {
                    try await outbox.discard(key)       // acknowledge first...
                    disk.checkpoint("delivered:\(index + 1)")   // ...the "send" would happen here
                    disk.checkpoint("acked:\(index + 1)")
                }
                try await outbox.close()
            },
            check: { disk, context in
                let outbox = try Self.open(disk, threshold: 64 * 1024)
                let present = Set(try await outbox.entries().map(\.key))
                let enqueued = Self.reached(context, "enq:")
                let delivered = Self.reached(context, "delivered:")
                for index in 0..<enqueued where index >= delivered && !present.contains(Self.keys[index]) {
                    return "entry \(index) lost before delivery"
                }
                return nil
            }
        )
        print(report)
        #expect(!report.violations.isEmpty)
        #expect(report.violations.allSatisfy { $0.message.contains("lost before delivery") })
    }
}
