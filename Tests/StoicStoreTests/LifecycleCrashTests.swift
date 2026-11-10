import Stoic
@testable import StoicStore
import StoicTesting
import Testing

/// design/27, amendment 3: `JournaledLifecycleStore`'s commit, hand-off,
/// recovery, `settleDue`'s batch, compaction, purge and the outbox's
/// remembered keys, crashed at every file operation, in every way the
/// simulated disk allows (design/15's `exploreCrashes`).
///
/// Serialized: the exploration is many thousand recoveries, and run on every
/// core at once it starves the suites that measure time (the outbox's
/// opening speed) running beside it.
@Suite("Lifecycle store crash consistency", .serialized)
struct LifecycleCrashTests {
    static let path = "/d/notices"
    static let ids = ["n1", "n2"]
    static func key(_ id: String) -> String { "\(id)-key-0123456789abcdefgh" }

    static func open(
        _ disk: SimulatedFileSystem, threshold: Int, defect: NoticeStore.Defect? = nil
    ) async throws -> NoticeStore {
        try await NoticeStore.open(
            at: path, fileSystem: disk, delivery: DeliveryPolicy(schedule: .immediate.attempts(1)), rememberSettled: 64,
            compactionThreshold: threshold, journalOptions: Journal.Options(), defect: defect)
    }

    /// Two notices: inserted, sent, delivered, lapsed by `settleDue` in one
    /// batch, the first finished and purged, the rest delivered. Each step
    /// that returned is a checkpoint; each acknowledgement that returned is
    /// `acked:<key>`.
    static func run(_ disk: SimulatedFileSystem, threshold: Int, defect: NoticeStore.Defect?) async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let store = try await open(disk, threshold: threshold, defect: defect)
            for id in ids {
                _ = try await store.insert(.make(.draft, by: "p", key: key(id)), as: id)
                disk.checkpoint("inserted:\(id)")
            }
            for id in ids {
                try await store.apply(.send, to: id, by: "p", because: "sent")
                disk.checkpoint("sent:\(id)")
            }
            try await deliver(store, disk)
            clock.jumpWallClock(by: .seconds(61))
            try await store.settleDue()
            disk.checkpoint("settled")
            try await store.apply(.finish, to: "n1", by: "p", because: "finished")
            disk.checkpoint("finished:n1")
            disk.checkpoint("purging")
            try await store.purge(finishedBefore: Moment.now + .seconds(1))
            disk.checkpoint("purged")
            try await deliver(store, disk)
            try await store.close()
        }
    }

    /// Delivers what is pending; once the run returns, every key it
    /// delivered has a durable acknowledgement.
    static func deliver(_ store: NoticeStore, _ disk: SimulatedFileSystem) async throws {
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await store.deliverEffects { _ in .delivered }
        }
        for key in report.delivered { disk.checkpoint("acked:\(key)") }
    }

    /// What must hold after any crash: the store opens; every record's
    /// history verifies; a step that returned survived; every effect in a
    /// recovered history is pending or settled in the outbox; nothing is
    /// pending that no surviving commit owes; and no acknowledged effect is
    /// pending again.
    static func invariant(threshold: Int, defect: NoticeStore.Defect?) -> (SimulatedFileSystem, CrashContext) async throws -> String? {
        { disk, context in
            try await withTestAmbient(clock: TestClock()) {
                let store = try await open(disk, threshold: threshold, defect: defect)
                let message = try await check(store, context)
                try await store.close()
                return message
            }
        }
    }

    static func check(_ store: NoticeStore, _ context: CrashContext) async throws -> String? {
        var owed: [String: Set<IdempotencyKey>] = [:]
        for (id, record) in await store.records() {
            let history = try await store.history(of: id)
            do throws(HistoryGap) {
                try LifecycleHistory.verify(history, of: record)
            } catch {
                return "\(id): \(error): a head without its entries"
            }
            owed[id] = Set(history.flatMap(\.effects))
        }
        let purgeStarted = context.reached("purging")
        for id in ids {
            let record = try await store.load(id)
            if context.reached("inserted:\(id)"), record == nil, !(id == "n1" && purgeStarted) {
                return "\(id) was inserted and is gone"
            }
            guard let record else { continue }
            if context.reached("sent:\(id)"), record.revision < 2 { return "\(id)'s send returned and is gone" }
            if context.reached("settled"), record.revision < 3 { return "\(id)'s settling returned and is gone" }
        }
        let pending = try await store.outbox.entries()
        for (id, keys) in owed {
            for key in keys {
                let isPending = pending.contains { $0.key == key }
                if !isPending, !(await store.outbox.isSettled(key)) {
                    return "\(id)'s committed effect \(key) is neither pending nor settled"
                }
            }
        }
        for entry in pending {
            if let keys = owed[entry.item.id] {
                if !keys.contains(entry.key) { return "\(entry.key) is pending but no surviving commit of \(entry.item.id) owes it" }
            } else if !(entry.item.id == "n1" && purgeStarted) {
                return "\(entry.key) is pending for \(entry.item.id), which has no commit"
            }
        }
        for checkpoint in context.checkpoints where checkpoint.operationCount <= context.crashPoint {
            guard checkpoint.label.hasPrefix("acked:") else { continue }
            let key = IdempotencyKey(rawValue: String(checkpoint.label.dropFirst("acked:".count)))
            if pending.contains(where: { $0.key == key }) { return "\(key) was acknowledged and is pending again" }
        }
        // The recovered store works: it delivers, takes a commit, and closes.
        _ = try await store.deliverEffects { _ in .delivered }
        _ = try await store.insert(.make(.draft, by: "p", key: "after-key-0123456789abcde"), as: "after")
        try await store.apply(.send, to: "after", by: "p", because: "after recovery")
        return nil
    }

    @Test(
        .failureMode("design/27", "the process dies at any point of a device commit"),
        .failureMode("design/27", "the process dies during `settleDue`, compaction or purge"),
        arguments: [256 * 1024, 1])
    func everyCrashLeavesOldOrNewHeadsWithTheirEntriesAndEffects(threshold: Int) async throws {
        let report = try await exploreCrashes(
            "lifecycle store threshold=\(threshold)",
            samples: 3,
            setup: { try $0.createDirectory("/d") },
            operation: { try await Self.run($0, threshold: threshold, defect: nil) },
            check: Self.invariant(threshold: threshold, defect: nil)
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.crashPoints >= 30)
    }

    /// Recovery writes too: it hands over what the last run owed the
    /// outbox, and may compact. A crash during it, at every one of its own
    /// file operations, must leave what a crash before it would. A short run
    /// keeps this affordable: one notice, sent, its effect owed.
    @Test(.failureMode("design/27", "the process dies during recovery at open"))
    func aCrashDuringRecoveryLeavesWhatACrashBeforeItWould() async throws {
        // Compacting at every chance: recovery's hand-off and its compaction.
        let threshold = 1
        let report = try await exploreCrashes(
            "lifecycle store recovery threshold=\(threshold)",
            samples: 2,
            setup: { try $0.createDirectory("/d") },
            operation: { try await Self.short($0, threshold: threshold, defect: nil, deliver: false) },
            recovery: { disk in
                try await withTestAmbient(clock: TestClock()) { try await Self.open(disk, threshold: threshold).close() }
            },
            check: Self.invariant(threshold: threshold, defect: nil)
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.recoveryImages > 0, "recovery was crashed too")
    }

    // MARK: The harness must catch these

    @Test func aStoreThatEnqueuesBeforeItAppendsFails() async throws {
        let report = try await Self.explore(.enqueueBeforeAppend)
        #expect(report.violations.contains { $0.message.contains("no surviving commit") || $0.message.contains("has no commit") })
    }

    @Test func aStoreThatAppendsHeadAndEntriesApartFails() async throws {
        let report = try await Self.explore(.headAndEntriesApart)
        #expect(report.violations.contains { $0.message.contains("a head without its entries") })
    }

    @Test func anOutboxThatForgetsSettledKeysFails() async throws {
        let report = try await Self.explore(.forgetSettled)
        // Caught first as a delivered effect the outbox no longer knows, and
        // where it was handed over again, as one acknowledged and pending.
        #expect(report.violations.contains { $0.message.contains("neither pending nor settled") })
        #expect(report.violations.allSatisfy {
            $0.message.contains("neither pending nor settled") || $0.message.contains("acknowledged and is pending again")
        })
    }

    /// One notice, inserted and sent; then, if `deliver`, its effect
    /// delivered with no append after: enough to show each defect.
    static func short(_ disk: SimulatedFileSystem, threshold: Int, defect: NoticeStore.Defect?, deliver: Bool) async throws {
        try await withTestAmbient(clock: TestClock()) {
            let store = try await Self.open(disk, threshold: threshold, defect: defect)
            _ = try await store.insert(.make(.draft, by: "p", key: Self.key("n1")), as: "n1")
            disk.checkpoint("inserted:n1")
            try await store.apply(.send, to: "n1", by: "p", because: "sent")
            disk.checkpoint("sent:n1")
            if deliver { try await Self.deliver(store, disk) }
            try await store.close()
        }
    }

    static func explore(_ defect: NoticeStore.Defect) async throws -> CrashReport {
        let report = try await exploreCrashes(
            "lifecycle store with \(defect)",
            samples: 2,
            setup: { try $0.createDirectory("/d") },
            operation: { try await Self.short($0, threshold: 256 * 1024, defect: defect, deliver: true) },
            check: Self.invariant(threshold: 256 * 1024, defect: defect)
        )
        print(report)
        return report
    }
}
