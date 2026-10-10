#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Observation
import Stoic
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Synchronization
import Testing

struct Prefs: Sendable, Equatable {
    var speed = 600
    var name = "default"

    /// Version 2: `scroll_speed` became `speed`.
    static let schema = Schema.object(
        Prefs.self, default: Prefs(), version: 2, migrations: [.from(1, to: 2, .rename("scroll_speed", to: "speed"))]
    ) {
        Field("speed", \.speed, .int(.range(100...4000)), doc: "Pixels per second.")
        Field("name", \.name, .string(.length(1...40)), doc: "A name.")
    }
}

@Suite("Settings store")
struct SettingsStoreTests {
    static let path = "/d/prefs.json"

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    static func open(_ disk: SimulatedFileSystem, format: SettingsStore<Prefs>.Format = .appOwned) throws -> SettingsStore<Prefs> {
        try SettingsStore.open(at: path, schema: Prefs.schema, format: format, fileSystem: disk)
    }

    /// Writes `text` as the settings file, as the given format stores it.
    static func place(_ text: String, on disk: SimulatedFileSystem, format: SettingsStore<Prefs>.Format = .handEdited) throws {
        try AtomicFile(fileSystem: disk, options: .init(envelope: format == .appOwned)).write(Array(text.utf8), to: path)
    }

    @Test func aFirstLaunchHasTheDefaultsAndWritesNothing() throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        #expect(settings.value == Prefs())
        #expect(settings.source == .defaults(.missing))
        #expect(try !disk.exists(Self.path))
    }

    @Test func anUpdateIsDurableAndSeenByTheNextLaunch() throws {
        let disk = try Self.disk()
        try Self.open(disk).update { $0.speed = 900 }
        let next = try Self.open(disk)
        #expect(next.value.speed == 900)
        #expect(next.source == .file)
    }

    @Test func anInvalidUpdateIsRefusedAndChangesNothing() throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        try settings.update { $0.speed = 900 }
        #expect(throws: SettingsStore<Prefs>.UpdateError.self) {
            try settings.update { $0.speed = 99_999; $0.name = "" }
        }
        #expect(settings.value.speed == 900)
        #expect(try Self.open(disk).value.speed == 900)
        do {
            try settings.update { $0.speed = 99_999; $0.name = "" }
        } catch SettingsStore<Prefs>.UpdateError.invalid(let issues) {
            #expect(issues.count == 2, "every problem, not the first")
        }
    }

    @Test func aFailedWriteChangesNothing() throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        disk.inject(ENOSPC, on: .write)
        #expect(throws: SettingsStore<Prefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        #expect(settings.value.speed == 600)
        disk.clearFaults()
        try settings.update { $0.speed = 901 }
        #expect(try Self.open(disk).value.speed == 901)
    }

    @Test func oneInvalidFieldFallsBackAloneAndIsReported() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 99999, "name": "kept"}"#, on: disk, format: .appOwned)
        let settings = try Self.open(disk)
        #expect(settings.value == Prefs(speed: 600, name: "kept"))
        #expect(settings.issues.contains { $0.severity == .repaired })
        // App-owned: the repair is written back.
        let reopened = try Self.open(disk)
        #expect(reopened.issues.isEmpty)
        #expect(reopened.value.name == "kept")
    }

    @Test func anUnusableFileIsQuarantinedAndThePreviousGenerationUsed() throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        try settings.update { $0.speed = 700 }
        try settings.update { $0.speed = 800 }   // 700 is now the previous generation
        try Self.place("this is not json", on: disk, format: .appOwned)
        let next = try Self.open(disk)
        #expect(next.value.speed == 700)
        #expect(next.source == .previousGeneration)
        #expect(try disk.list(directory: "/d").contains { $0.contains(".corrupt-") }, "quarantined, not deleted")
    }

    @Test func nothingUsableMeansDefaults() throws {
        let disk = try Self.disk()
        try Self.place("[1, 2", on: disk, format: .appOwned)
        let settings = try Self.open(disk)
        #expect(settings.value == Prefs())
        #expect(settings.source == .defaults(.unusable))
    }

    @Test func anOldFormatIsMigratedWrittenBackAndKeptAsPrevious() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 1, "scroll_speed": 1200}"#, on: disk, format: .appOwned)
        let settings = try Self.open(disk)
        #expect(settings.value.speed == 1200)
        #expect(settings.issues.contains { $0.code == .migrated })
        let reopened = try Self.open(disk)
        #expect(!reopened.issues.contains { $0.code == .migrated }, "written back in the new format")
        let previous = try #require(try AtomicFile(fileSystem: disk).read(Self.path + ".previous"))
        #expect(String(decoding: previous.bytes, as: UTF8.self).contains("scroll_speed"), "the old file survives for a downgrade")
    }

    @Test func aNewerFormatIsReadOnlyAndNeverOverwritten() throws {
        let disk = try Self.disk()
        let newer = #"{"version": 3, "speed": 1500, "hyperdrive": true}"#
        try Self.place(newer, on: disk, format: .appOwned)
        let settings = try Self.open(disk)
        guard case .newerFormat(let version) = settings.source else {
            Issue.record("expected newerFormat, got \(settings.source)")
            return
        }
        #expect(version == 3)
        #expect(throws: SettingsStore<Prefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        let onDisk = try #require(try AtomicFile(fileSystem: disk).read(Self.path))
        #expect(String(decoding: onDisk.bytes, as: UTF8.self) == newer, "the newer app's file is untouched")
        #expect(try !disk.list(directory: "/d").contains { $0.contains(".corrupt-") })
    }

    @Test func aHandEditedFileAllowsCommentsAndIsNotRewrittenOnLoad() throws {
        let disk = try Self.disk()
        let text = """
        {
          // set by hand
          "version": 2,
          "speed": 99999,
        }
        """
        try Self.place(text, on: disk)
        let settings = try Self.open(disk, format: .handEdited)
        #expect(settings.value.speed == 600)
        #expect(settings.issues.contains { $0.severity == .repaired })
        let onDisk = try #require(try AtomicFile(fileSystem: disk, options: .init(envelope: false)).read(Self.path))
        #expect(String(decoding: onDisk.bytes, as: UTF8.self) == text)
    }

    @Test func observersSeeCommittedChanges() throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        let changed = Mutex(false)
        withObservationTracking {
            _ = settings.value
        } onChange: {
            changed.withLock { $0 = true }
        }
        try settings.update { $0.speed = 600 }   // no change: no notification
        #expect(!changed.withLock { $0 })
        try settings.update { $0.speed = 650 }
        #expect(changed.withLock { $0 })
    }

    @Test func concurrentUpdatesAreSerialised() async throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { try settings.update { $0.speed += 1 } }
            }
            try await group.waitForAll()
        }
        #expect(settings.value.speed == 700)
        #expect(try Self.open(disk).value.speed == 700)
    }

    @Test func aCrashAtAnyPointOfAnUpdateLeavesTheOldValueOrTheNew() throws {
        let disk = try Self.disk()
        try Self.open(disk).update { $0.speed = 700 }
        disk.settle()
        let start = disk.operationCount
        try Self.open(disk).update { $0.speed = 800 }
        var images = 0
        for point in start...disk.operationCount {
            for image in disk.crashImages(afterOperation: point, samples: 8, seed: UInt64(point)) {
                images += 1
                let recovered = try SettingsStore.open(at: Self.path, schema: Prefs.schema, fileSystem: image.fileSystem)
                #expect([700, 800].contains(recovered.value.speed), "crash after \(point): \(image.description)")
                #expect(recovered.source == .file || recovered.source == .previousGeneration, "never fell back to defaults")
            }
        }
        #expect(images > 10)
    }
}
