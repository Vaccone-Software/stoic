@testable import StoicStore
import StoicTesting
import Testing

@Suite("Journal crash consistency")
struct JournalCrashTests {
    static let path = "/d/journal"

    static func prepare(_ disk: SimulatedFileSystem) throws {
        try disk.createDirectory("/d")
    }

    /// What recovery reconstructs: the snapshot's folded records (joined by
    /// `|`) followed by the records after it.
    static func recovered(_ disk: SimulatedFileSystem) throws -> [String] {
        let journal = try Journal.open(at: path, fileSystem: disk)
        defer { _ = try? journal.close() }
        let replay = try journal.replay()
        let sequences = replay.records.map(\.sequence)
        guard sequences == sequences.sorted(), Set(sequences).count == sequences.count else {
            throw StoreError(kind: .corrupt, operation: "check", detail: "sequences out of order: \(sequences)")
        }
        return records(of: replay)
    }

    /// The journal invariant: recovery yields a prefix of what was appended,
    /// at least as long as what was acknowledged, and the journal can be
    /// appended to and reopened afterwards.
    static func invariant(appended: [String], preexisting: [String] = []) -> (SimulatedFileSystem, CrashContext) throws -> String? {
        { disk, context in
            let acknowledged = context.checkpointsReached(prefix: "ack:")
                .compactMap { Int($0.dropFirst(4)) }.max() ?? 0
            let all = preexisting + appended
            let found = try recovered(disk)
            guard found.count <= all.count, found == Array(all.prefix(found.count)) else {
                return "recovered \(found), which is not a prefix of \(all)"
            }
            guard found.count >= preexisting.count + acknowledged else {
                return "recovered \(found) but \(preexisting.count + acknowledged) records were acknowledged"
            }
            // Recovery repairs; the repaired journal must be usable and stable.
            let journal = try Journal.open(at: path, fileSystem: disk)
            try journal.append(bytes("after"))
            try journal.close()
            let again = try recovered(disk)
            guard again == found + ["after"] else { return "after recovery and one more append, found \(again), not \(found + ["after"])" }
            return nil
        }
    }

    /// The records a replay stands for, snapshot first.
    static func records(of replay: Journal.Replay) -> [String] {
        let folded = replay.snapshot.map { text($0.bytes).split(separator: "|").map(String.init) } ?? []
        return folded + replay.records.map { text($0.bytes) }
    }

    /// A compaction's fold: the whole history so far, joined by `|`.
    static func fold(_ replay: Journal.Replay) -> [UInt8] {
        bytes(records(of: replay).joined(separator: "|"))
    }

    static func appendOneByOne(_ names: [String], on disk: SimulatedFileSystem, openFirst: Bool = true) throws {
        let journal = try Journal.open(at: path, fileSystem: disk)
        for (index, name) in names.enumerated() {
            try journal.append(bytes(name))
            disk.checkpoint("ack:\(index + 1)")
        }
        try journal.close()
    }

    @Test(.failureMode("design/15", "append has returned, then power is lost")) func eachAppendIsDurableBeforeItReturns() async throws {
        let names = ["alpha", "bravo", "charlie", "delta", "echo"]
        let report = try await exploreCrashes(
            "Journal.append x5",
            setup: Self.prepare,
            operation: { try Self.appendOneByOne(names, on: $0) },
            recovery: { disk in _ = try Self.recovered(disk) },
            check: Self.invariant(appended: names)
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.crashPoints >= 12)
    }

    @Test func aBatchIsAllOrAPrefixAndDurableOnceItReturns() async throws {
        let batch = ["b1", "b2", "b3", "b4"]
        let report = try await exploreCrashes(
            "Journal.append(batch:)",
            setup: { disk in
                try Self.prepare(disk)
                let journal = try Journal.open(at: Self.path, fileSystem: disk)
                try journal.append(bytes("old"))
                try journal.close()
            },
            operation: { disk in
                let journal = try Journal.open(at: Self.path, fileSystem: disk)
                try journal.append(batch: batch.map(bytes))
                disk.checkpoint("ack:\(batch.count)")
                try journal.close()
            },
            check: Self.invariant(appended: batch, preexisting: ["old"])
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
    }

    @Test func aTornTailFromEarlierIsRepairedAtOpenEvenIfRepairIsInterrupted() async throws {
        let report = try await exploreCrashes(
            "Journal.open repairing a torn tail",
            setup: { disk in
                try Self.prepare(disk)
                let journal = try Journal.open(at: Self.path, fileSystem: disk)
                try journal.append(bytes("one"))
                try journal.append(bytes("two"))
                try journal.close()
                // A third record, torn after 11 bytes, as a crash would have left it.
                let torn = Array(Journal.frame(bytes("three"), sequence: 3).prefix(11))
                let file = try disk.open(Self.path, mode: .readWrite)
                try disk.write(file, torn, at: try disk.size(of: file))
                try disk.fullSync(file)
                try disk.close(file)
            },
            operation: { disk in
                try Self.appendOneByOne(["four", "five"], on: disk)
            },
            recovery: { disk in _ = try Self.recovered(disk) },
            check: Self.invariant(appended: ["four", "five"], preexisting: ["one", "two"])
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.recoveryImages > 0)
    }

    @Test(.failureMode("design/15", "a crash falls inside compact")) func compactionIsCorrectAtEveryCrashPoint() async throws {
        let before = ["a", "b", "c"]
        let after = ["d", "e"]
        let report = try await exploreCrashes(
            "Journal.compact",
            setup: { disk in
                try Self.prepare(disk)
                let journal = try Journal.open(at: Self.path, fileSystem: disk)
                for name in before { try journal.append(bytes(name)) }
                try journal.close()
            },
            operation: { disk in
                let journal = try Journal.open(at: Self.path, fileSystem: disk)
                try journal.compact(Self.fold)
                disk.checkpoint("compacted")
                for (index, name) in after.enumerated() {
                    try journal.append(bytes(name))
                    disk.checkpoint("ack:\(index + 1)")
                }
                try journal.close()
            },
            recovery: { disk in _ = try Self.recovered(disk) },
            check: Self.invariant(appended: after, preexisting: before)
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.crashPoints >= 10)
    }

    @Test func twoCompactionsInARowNeverLoseOrRepeatARecord() async throws {
        let report = try await exploreCrashes(
            "Journal.compact twice",
            setup: Self.prepare,
            operation: { disk in
                let journal = try Journal.open(at: Self.path, fileSystem: disk)
                try journal.append(bytes("a"))
                disk.checkpoint("ack:1")
                try journal.compact(Self.fold)
                try journal.append(bytes("b"))
                disk.checkpoint("ack:2")
                try journal.compact(Self.fold)
                try journal.append(bytes("c"))
                disk.checkpoint("ack:3")
                try journal.close()
            },
            check: Self.invariant(appended: ["a", "b", "c"])
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
    }

    // MARK: The harness must be able to fail here too

    @Test func aJournalThatDoesNotSyncItsDirectoryOnCreationLosesTheFirstRecords() async throws {
        // The same appends, but the journal file's name is never made durable.
        let report = try await exploreCrashes(
            "journal without directory sync",
            setup: Self.prepare,
            operation: { disk in
                let file = try disk.open(Self.path, mode: .readWriteCreate)   // created, directory never synced
                var end = 0
                for (index, name) in ["x", "y"].enumerated() {
                    let frame = Journal.frame(bytes(name), sequence: UInt64(index + 1))
                    try disk.write(file, frame, at: end)
                    try disk.fullSync(file)
                    end += frame.count
                    disk.checkpoint("ack:\(index + 1)")
                }
            },
            check: Self.invariant(appended: ["x", "y"])
        )
        print(report)
        for violation in report.violations.prefix(1) { print("  ", violation) }
        #expect(!report.violations.isEmpty)
        #expect(report.violations.allSatisfy { $0.message.contains("acknowledged") })
    }

    @Test func aJournalThatAcknowledgesBeforeSyncingLosesRecords() async throws {
        let report = try await exploreCrashes(
            "journal acknowledging before fullSync",
            setup: { disk in
                try Self.prepare(disk)
                let journal = try Journal.open(at: Self.path, fileSystem: disk)
                try journal.close()
            },
            operation: { disk in
                let file = try disk.open(Self.path, mode: .readWrite)
                var end = 0
                for (index, name) in ["x", "y"].enumerated() {
                    let frame = Journal.frame(bytes(name), sequence: UInt64(index + 1))
                    try disk.write(file, frame, at: end)
                    end += frame.count
                    disk.checkpoint("ack:\(index + 1)")   // no fullSync
                }
            },
            check: Self.invariant(appended: ["x", "y"])
        )
        print(report)
        #expect(!report.violations.isEmpty)
    }

    @Test func aRecoveryThatDoesNotTruncateTheTailHidesLaterRecords() throws {
        // Scan the tail but leave it on disk: records appended after it are
        // unreachable on the next open. The invariant's "append after
        // recovery, then reopen" step is what catches it.
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        let journal = try Journal.open(at: Self.path, fileSystem: disk)
        try journal.append(bytes("one"))
        try journal.close()
        let file = try disk.open(Self.path, mode: .readWrite)
        let end = try disk.size(of: file)
        try disk.write(file, Array(Journal.frame(bytes("torn"), sequence: 2).prefix(9)), at: end)
        try disk.fullSync(file)
        // A broken recovery appends after the garbage instead of cutting it.
        let garbageEnd = try disk.size(of: file)
        try disk.write(file, Journal.frame(bytes("two"), sequence: 2), at: garbageEnd)
        try disk.fullSync(file)
        try disk.close(file)
        #expect(try Self.recovered(disk) == ["one"])   // "two" is unreachable: exactly the bug
    }
}

extension CrashContext {
    /// The labels of checkpoints with `prefix` reached by this crash point.
    func checkpointsReached(prefix: String) -> [String] {
        checkpoints.filter { $0.label.hasPrefix(prefix) && $0.operationCount <= crashPoint }.map(\.label)
    }
}
