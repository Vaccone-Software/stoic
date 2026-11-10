import Foundation
import Stoic
import StoicJSON
import StoicSchema
import StoicSchemaTesting
@testable import StoicStore
import StoicTesting
import Testing

/// What released builds' stores wrote, read by this one (design/32): the
/// fixtures in Compatibility/, each recorded by the release in its folder's
/// name, with that release's own code.
@Suite("Store: the files released builds wrote")
struct StoreCompatibilityTests {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Compatibility")
    typealias Record = LifecycleRecord<CompatRelease>
    typealias Entry = LifecycleEntry<CompatRelease>

    /// What each recorded record must say: its state and its revision.
    static let records: [String: (state: CompatRelease.State, revision: UInt64)] = [
        "running": (.running, 5), "stalled": (.offered, 3),
    ]

    /// Every release's fixtures of a Codable format, read by the store's own
    /// decoder; each must re-encode to the very bytes it was read from, which
    /// is what proves that release reads what this one writes: it has no
    /// reader to offer documents to (a Codable leaf's schema is `{}`).
    static func check<Value: Codable & Sendable>(
        _ format: String, _ type: Value.Type, verify: @escaping @Sendable (CompatibilityFixture, Value) -> [String]
    ) throws -> CompatibilityReport {
        let set = try loadCompatibilitySet(format: format, from: directory.path)
        var check = CompatibilityCheck(Schema<Value>.codable(type))
        check.reading = { bytes in
            guard let value = LifecycleStoreFormat.decode(type, from: bytes) else {
                return Decoded(value: nil, issues: [Issue(code: .invalidFormat, parameters: ["reason": .string("does not decode")])])
            }
            return Decoded(value: value, issues: [])
        }
        check.generated = 0
        check.verify = { fixture, value in
            let again = try? LifecycleStoreFormat.encode(value, "a fixture")
            let bytes = again == fixture.bytes ? [] : ["re-encodes as \(String(decoding: again ?? [], as: UTF8.self))"]
            return bytes + verify(fixture, value)
        }
        return check.report(set)
    }

    @Test func aLifecycleRecordReadsAsTheReleaseWroteIt() throws {
        let report = try Self.check("lifecycle.lodestar.release", Record.self) { fixture, record in
            guard let expected = Self.records[fixture.name] else { return ["no record is named \"\(fixture.name)\""] }
            let written = record.written
            return written.state == expected.state && record.revision == expected.revision
                ? [] : ["reads as \(written.state) at revision \(record.revision), not \(expected.state) at \(expected.revision)"]
        }
        #expect(report.failures.isEmpty, "\(report)")
        #expect(report.read == 2)
        #expect(Set(report.warnings.map(\.code)) == ["no_reader"], "\(report)")
    }

    @Test func aLifecycleEntryReadsAsTheReleaseWroteIt() throws {
        let report = try Self.check("lifecycle.lodestar.release.entry", Entry.self) { fixture, entry in
            // `running-4` is the fourth entry of the record `running`.
            let number = fixture.name.split(separator: "-").last.flatMap { UInt64($0) }
            return entry.sequence + 1 == number ? [] : ["holds entry \(entry.sequence), not \((number ?? 0) - 1)"]
        }
        #expect(report.failures.isEmpty, "\(report)")
        #expect(report.read == 6)
        #expect(Set(report.warnings.map(\.code)) == ["no_reader"], "\(report)")
    }

    /// The store's files as a release left them, each `<name>.bin` at
    /// `/d/<name>`.
    static func disk(_ format: String, release: String) throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        let folder = directory.appending(path: format).appending(path: release)
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".bin") {
            let bytes = Array(try Data(contentsOf: folder.appending(path: file)))
            try AtomicFile(fileSystem: disk, options: .init(envelope: false)).write(bytes, to: "/d/\(file.dropLast(".bin".count))")
        }
        return disk
    }

    @Test func aLifecycleStoreOpensAsTheReleaseLeftIt() async throws {
        let disk = try Self.disk("lifecycle.journal", release: "0.7.0")
        try await withTestAmbient(clock: TestClock()) {
            let store = try await JournaledLifecycleStore<CompatRelease, String>.open(at: "/d/releases", fileSystem: disk)
            #expect(await store.records().map(\.id) == ["0.56", "0.55"])
            for (id, name) in [("0.56", "running"), ("0.55", "stalled")] {
                let fixture = Self.directory.appending(path: "lifecycle.lodestar.release/0.7.0/\(name).json")
                let recorded = try #require(LifecycleStoreFormat.decode(Record.self, from: Array(try Data(contentsOf: fixture))))
                #expect(try await store.load(id) == recorded)
            }
            #expect(try await store.history(of: "0.56").map(\.to) == [.downloading, .staged, .applying, .running])
            #expect(try await store.history(of: "0.55").map(\.to) == [.downloading, .offered])
            // And it goes on from there: the stalled release is offered again.
            try await store.apply(.download, to: "0.55", by: .updater, because: "a second try")
            try await store.close()
            let reopened = try await JournaledLifecycleStore<CompatRelease, String>.open(at: "/d/releases", fileSystem: disk)
            #expect(try await reopened.load("0.55")?.written.state == .downloading)
            try await reopened.close()
        }
    }

    /// The scenario 0.7.0 recorded, run by today's store, writes the bytes
    /// 0.7.0 wrote, journal and effects alike: so 0.7.0 reads them.
    @Test func theLifecycleStoreWritesTheBytes070Wrote() async throws {
        let recorded = try Self.disk("lifecycle.journal", release: "0.7.0")
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        try await recordReleases(at: "/d/releases", on: disk)
        for path in ["/d/releases", "/d/releases.effects"] {
            let today = try #require(disk.contents(of: path))
            #expect(today == recorded.contents(of: path), "\(path): \(today.count) bytes today")
        }
    }

    @Test func anOutboxOpensAsTheReleaseLeftIt() async throws {
        let disk = try Self.disk("outbox.journal", release: "0.7.0")
        let outbox = try Outbox<CompatMessage>.open(at: "/d/outbox", codec: .json(), fileSystem: disk)
        let entries = try await outbox.entries()
        #expect(entries.map(\.key.rawValue) == ["kept-1", "kept-2", "after-snapshot"])
        #expect(entries.map(\.item.to) == ["ben@kindora.example", "cleo@kindora.example", "dan@kindora.example"])
        // Delivered in order, and gone once delivered.
        var delivered: [String] = []
        _ = try await outbox.deliverPending { entry in
            delivered.append(entry.key.rawValue)
            return .delivered
        }
        #expect(delivered == ["kept-1", "kept-2", "after-snapshot"])
        try await outbox.close()
        let reopened = try Outbox<CompatMessage>.open(at: "/d/outbox", codec: .json(), fileSystem: disk)
        #expect(await reopened.pendingCount == 0)
        try await reopened.close()
    }
}
