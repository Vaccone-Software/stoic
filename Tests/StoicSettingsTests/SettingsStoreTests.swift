#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Observation
import Stoic
import StoicJSON
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

extension JSONValue {
    /// The member of an object, for reading a settings file back in a test.
    subscript(key: String) -> JSONValue? { object?[key] }
}

/// Settings with a nested object, for keys an older build does not know.
struct NestedPrefs: Sendable, Equatable {
    struct Editor: Sendable, Equatable {
        var font = 12
    }

    var speed = 600
    var editor = Editor()

    static let editorSchema = Schema.object(Editor.self, default: Editor()) {
        Field("font", \.font, .int(.range(6...72)))
    }

    static let schema = Schema.object(NestedPrefs.self, default: NestedPrefs(), version: 2) {
        Field("speed", \.speed, .int(.range(100...4000)))
        Field("editor", \.editor, NestedPrefs.editorSchema)
    }
}

/// Settings that hold a credential.
struct AccountPrefs: Sendable, Equatable {
    var user = "anon"
    var token = ""

    static let schema = Schema.object(AccountPrefs.self, default: AccountPrefs()) {
        Field("user", \.user, .string())
        Field("token", \.token, .string(), secret: true)
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

    @Test(.failureMode("design/18", "there is no file")) func aFirstLaunchHasTheDefaultsAndWritesNothing() throws {
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

    @Test(.failureMode("design/18", "an update produces an invalid value")) func anInvalidUpdateIsRefusedAndChangesNothing() throws {
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

    @Test(.failureMode("design/18", "the write fails (disk full, read-only volume)")) func aFailedWriteChangesNothing() throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        disk.inject(ENOSPC, on: .write)
        #expect(throws: SettingsStore<Prefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        #expect(settings.value.speed == 600)
        disk.clearFaults()
        try settings.update { $0.speed = 901 }
        #expect(try Self.open(disk).value.speed == 901)
    }

    @Test(.failureMode("design/18", "one field is invalid")) func oneInvalidFieldFallsBackAloneAndIsReported() throws {
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

    @Test(.failureMode("design/18", "the file is torn or not JSON")) func anUnusableFileIsQuarantinedAndThePreviousGenerationUsed() throws {
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

    @Test(.failureMode("design/18", "the document is an older version")) func anOldFormatIsMigratedWrittenBackAndKeptAsPrevious() throws {
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

    @Test(.failureMode("design/18", "the document is a newer version")) func aNewerFormatIsReadOnlyAndNeverOverwritten() throws {
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

    @Test(.failureMode("design/18", "two updates race")) func concurrentUpdatesAreSerialised() async throws {
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

    @Test(.failureMode("design/18", "the app crashed mid-save")) func aCrashAtAnyPointOfAnUpdateLeavesTheOldValueOrTheNew() throws {
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

    // MARK: Keys an older build does not know

    /// The text of the settings file as the store left it, whichever format.
    static func onDisk(_ disk: SimulatedFileSystem, format: SettingsStore<Prefs>.Format = .appOwned) throws -> JSONValue {
        let stored = try #require(try AtomicFile(fileSystem: disk, options: .init(envelope: format == .appOwned, keepPrevious: true)).read(path))
        return try JSONParser(options: .jsonc).parseValue(stored.bytes)
    }

    @Test(.failureMode("design/18", "the document has keys the schema does not declare"),
          arguments: [SettingsStore<Prefs>.Format.appOwned, .handEdited])
    func anUpdateKeepsTheKeysANewerBuildAdded(format: SettingsStore<Prefs>.Format) throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 500, "addedByNewerBuild": {"deep": [1, 2, {"x": null}]}, "flag": true}"#, on: disk, format: format)
        let settings = try Self.open(disk, format: format)
        try settings.update { $0.speed = 700 }
        let document = try Self.onDisk(disk, format: format)
        #expect(document == (try JSONParser().parseValue(#"{"version": 2, "speed": 700, "addedByNewerBuild": {"deep": [1, 2, {"x": null}]}, "flag": true}"#)))
        // And they survive any number of further updates and a relaunch.
        try settings.update { $0.name = "later" }
        let reopened = try Self.open(disk, format: format)
        #expect(reopened.value == Prefs(speed: 700, name: "later"))
        try reopened.update { $0.speed = 800 }
        #expect(try Self.onDisk(disk, format: format)["addedByNewerBuild"] != nil)
        #expect(try Self.onDisk(disk, format: format)["flag"] == .bool(true))
    }

    @Test func theKeysAreKeptThroughTheWriteBackOfARepair() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 99999, "addedByNewerBuild": 1}"#, on: disk, format: .appOwned)
        _ = try Self.open(disk)   // repairs speed and writes the repair back
        let document = try Self.onDisk(disk)
        #expect(document["addedByNewerBuild"] == .number(JSONNumber(1)))
        #expect(document["speed"] == nil, "the repaired field is back to its default, which sparse output omits")
    }

    @Test func anAppThatAsksToDropUnknownKeysDropsThem() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 500, "addedByNewerBuild": 1}"#, on: disk, format: .appOwned)
        let settings = try SettingsStore.open(at: Self.path, schema: Prefs.schema, unknownKeys: .drop, fileSystem: disk)
        try settings.update { $0.speed = 700 }
        #expect(try Self.onDisk(disk)["addedByNewerBuild"] == nil)
    }

    @Test func aMigratedDocumentDoesNotCarryTheKeysItMigratedAway() throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 1, "scroll_speed": 1200, "legacy": true}"#, on: disk, format: .appOwned)
        let settings = try Self.open(disk)
        try settings.update { $0.name = "after" }
        let document = try Self.onDisk(disk)
        #expect(document["scroll_speed"] == nil)
        #expect(document["legacy"] == nil, "a version-1 key the version-2 schema does not know is legacy, not a newer build's")
        #expect(document["speed"] == .number(JSONNumber(1200)))
    }

    @Test func unknownKeysInANestedObjectAreKeptToo() throws {
        let disk = try Self.disk()
        let path = "/d/nested.json"
        try AtomicFile(fileSystem: disk).write(
            Array(#"{"version": 2, "speed": 500, "editor": {"font": 20, "ligatures": "on"}, "extra": 1}"#.utf8), to: path)
        let settings = try SettingsStore.open(at: path, schema: NestedPrefs.schema, fileSystem: disk)
        try settings.update { $0.editor.font = 14 }
        try settings.update { $0.speed = 900 }
        let stored = try #require(try AtomicFile(fileSystem: disk).read(path))
        let document = try JSONParser().parseValue(stored.bytes)
        #expect(document["editor"]?["ligatures"] == .string("on"))
        #expect(document["editor"]?["font"] == .number(JSONNumber(14)))
        #expect(document["extra"] == .number(JSONNumber(1)))
    }

    @Test func nestedUnknownKeysSurviveWhenTheNestedObjectGoesBackToDefaults() throws {
        let disk = try Self.disk()
        let path = "/d/nested.json"
        try AtomicFile(fileSystem: disk).write(
            Array(#"{"version": 2, "editor": {"font": 20, "ligatures": "on"}}"#.utf8), to: path)
        let settings = try SettingsStore.open(at: path, schema: NestedPrefs.schema, fileSystem: disk)
        try settings.update { $0.editor.font = 12 }   // sparse output would omit the whole object
        let document = try JSONParser().parseValue(try #require(try AtomicFile(fileSystem: disk).read(path)).bytes)
        #expect(document["editor"]?["ligatures"] == .string("on"))
        #expect(document["editor"]?["font"] == nil)
    }

    // MARK: Permissions

    @Test(.failureMode("design/18", "the file is created or replaced"))
    func theFileIsCreatedReadableByItsOwnerAlone() throws {
        let disk = try Self.disk()
        let settings = try SettingsStore.open(at: "/d/account.json", schema: AccountPrefs.schema, fileSystem: disk)
        try settings.update { $0.token = "hunter2" }
        #expect(try disk.permissions(of: "/d/account.json") == 0o600)
        // The secret is in the file, in plain text: the mode and the app's
        // sandbox are what protect it (design/18).
        #expect(String(decoding: disk.contents(of: "/d/account.json") ?? [], as: UTF8.self).contains("hunter2"))
        try settings.update { $0.user = "someone" }
        #expect(try disk.permissions(of: "/d/account.json") == 0o600)
        #expect(try disk.permissions(of: "/d/account.json.previous") == 0o600)
    }

    @Test(arguments: [SettingsStore<Prefs>.Format.appOwned, .handEdited])
    func anUpdateKeepsTheModeTheFileAlreadyHas(format: SettingsStore<Prefs>.Format) throws {
        let disk = try Self.disk()
        try Self.place(#"{"version": 2, "speed": 500}"#, on: disk, format: format)
        let file = try disk.open(Self.path, mode: .readWrite)
        try disk.setPermissions(file, to: 0o640)
        try disk.close(file)
        try Self.open(disk, format: format).update { $0.speed = 700 }
        #expect(try disk.permissions(of: Self.path) == 0o640)
    }

    @Test(.failureMode("design/18", "the settings file is a symbolic link"),
          arguments: [SettingsStore<Prefs>.Format.appOwned, .handEdited])
    func aSettingsFileThatIsALinkIsUpdatedThroughItAndStaysALink(format: SettingsStore<Prefs>.Format) throws {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/dotfiles")
        try disk.createDirectory("/d")
        let target = "/dotfiles/prefs.json"
        try AtomicFile(fileSystem: disk, options: .init(envelope: format == .appOwned))
            .write(Array(#"{"version": 2, "speed": 500}"#.utf8), to: target)
        disk.symlink(at: Self.path, to: target)

        let settings = try Self.open(disk, format: format)
        #expect(settings.value.speed == 500)
        try settings.update { $0.speed = 900 }

        #expect(try disk.readLink(Self.path) == target, "still a link")
        #expect(try Self.open(disk, format: format).value.speed == 900)
        let stored = try #require(try AtomicFile(fileSystem: disk, options: .init(envelope: format == .appOwned)).read(target))
        #expect(String(decoding: stored.bytes, as: UTF8.self).contains("900"), "the target holds the new value")
        #expect(try disk.list(directory: "/d") == ["prefs.json"])
    }

    // MARK: Reload and update

    /// Runs `body` on another thread and waits for it, but only briefly: a
    /// body that cannot finish because it is waiting for a lock the caller
    /// holds is the *correct* outcome for the code under test.
    static func runConcurrently(_ body: @escaping @Sendable () throws -> Void, waitingUpTo seconds: Double = 0.25) -> Thread {
        let thread = Thread { try? body() }
        thread.start()
        let deadline = Date().addingTimeInterval(seconds)
        while !thread.isFinished, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        return thread
    }

    @Test(.failureMode("design/18", "a reload races an update"))
    func anUpdateThatLandsDuringAReloadIsNotOverwrittenByItsStaleRead() throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        try settings.update { $0.speed = 650 }

        // Hold the reload exactly between reading the file (speed 650) and
        // publishing what it read, and let an update run there.
        let updater = Mutex<Thread?>(nil)
        settings.betweenReloadAndPublish.withLock {
            $0 = { updater.withLock { $0 = Self.runConcurrently { try settings.update { $0.speed = 700 } } } }
        }
        try settings.reload()
        settings.betweenReloadAndPublish.withLock { $0 = nil }

        // However the two were ordered, the update was not lost: what is
        // published is what is on disk, and it is the update's.
        while updater.withLock({ $0 })?.isFinished == false { Thread.sleep(forTimeInterval: 0.002) }
        #expect(settings.value.speed == 700)
        #expect(try Self.open(disk).value.speed == 700)
    }

    @Test func reloadingWhileUpdatingNeverLeavesTheStoreBehindTheFile() async throws {
        let disk = try Self.disk()
        let settings = try Self.open(disk)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for _ in 0..<300 { try settings.update { $0.speed += 1 } } }
            group.addTask { for _ in 0..<300 { try settings.reload() } }
            group.addTask { for _ in 0..<300 { try settings.reload() } }
            try await group.waitForAll()
        }
        #expect(settings.value.speed == 900)
        try settings.reload()
        #expect(settings.value.speed == 900)
        #expect(try Self.open(disk).value.speed == 900)
    }
}
