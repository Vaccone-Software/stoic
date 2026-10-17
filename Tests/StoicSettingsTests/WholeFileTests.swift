import Foundation
import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Writing the whole file on purpose: the file a first launch leaves to edit, and the reset of one that cannot be read.
@Suite("Settings store: materializing and replacing the file")
struct WholeFileTests {
    static let path = HandEditedTests.path
    static let garbage = HandEditedTests.garbage

    static func open(
        _ disk: SimulatedFileSystem, options: SettingsStore<LodePrefs>.Options = HandEditedTests.header()
    ) throws -> SettingsStore<LodePrefs> {
        try HandEditedTests.open(disk, options: options)
    }

    // MARK: Materializing

    @Test(.failureMode("design/18", "there is no file and the app materializes it"))
    func aMissingFileIsWrittenSparseWithTheHeaderAndMode0600() async throws {
        let disk = try HandEditedTests.disk()
        let events = RecordingInstrumentation()
        let settings = try Self.open(disk)
        let wrote = try await withAmbient({ $0.instrumentation = events }) { try settings.materialize() }
        #expect(wrote)
        #expect(HandEditedTests.text(disk) == "{\n  \"$schema\": \"lodestar-schema.json\",\n  \"version\": 2\n}\n")
        #expect(try disk.permissions(of: Self.path) == 0o600)
        #expect(settings.value == LodePrefs())
        #expect(settings.source == .file, "the file is now what the value came from")
        #expect(events.events(named: "settings.materialized").count == 1)
        #expect(try Self.open(disk).value == LodePrefs())
    }

    @Test(.failureMode("design/18", "there is no file and the app materializes it"))
    func theCurrentValueIsWhatIsWrittenNotAlwaysTheDefaults() throws {
        // The app set a value; the file was then deleted by the person. The deletion is adopted first, as an update does.
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        try settings.update { $0.speed = 900 }
        try disk.remove(Self.path)
        #expect(try settings.materialize())
        #expect(settings.value == LodePrefs(), "a deleted file is the defaults")
        #expect(try Self.open(disk).value == LodePrefs())
    }

    @Test(.failureMode("design/18", "a file is there and the app materializes it"))
    func aFileThatIsThereIsNeverTouchedWhateverItHolds() async throws {
        for text in [#"{"version": 2, "speed": 700}"#, Self.garbage, ""] {
            let disk = try HandEditedTests.disk()
            try HandEditedTests.place(text, on: disk)
            let events = RecordingInstrumentation()
            let settings = try Self.open(disk)
            let wrote = try await withAmbient({ $0.instrumentation = events }) { try settings.materialize() }
            #expect(!wrote)
            #expect(HandEditedTests.text(disk) == text, "byte for byte")
            #expect(events.events(named: "settings.materialized").isEmpty)
            try HandEditedTests.expectNothingBesideTheFile(disk)
        }
    }

    @Test(.failureMode("design/18", "two processes materialize the file at once"))
    func theSecondOfTwoStartersFindsTheFileThereAndWritesNothing() throws {
        let disk = try HandEditedTests.disk()
        let first = try Self.open(disk)
        let second = try Self.open(disk)
        #expect(try first.materialize())
        let written = disk.contents(of: Self.path)
        #expect(try !second.materialize())
        #expect(disk.contents(of: Self.path) == written)
    }

    @Test(.failureMode("design/18", "another process holds the lock on a hand-edited file"))
    func materializingDoesNotWaitForTheLock() throws {
        let disk = try HandEditedTests.disk()
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let settings = try Self.open(disk)
        let error = #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.materialize() }
        guard case .busy? = error else {
            Issue.record("expected .busy, got \(String(describing: error))")
            return
        }
        #expect(disk.contents(of: Self.path) == nil)
        try tool.release()
        #expect(try settings.materialize())
    }

    @Test(.failureMode("design/18", "the file cannot be written when the app materializes it"))
    func aFailedWriteLeavesNoFileAndTheNextTryWrites() throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        disk.inject(ENOSPC, on: .write)
        let error = #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.materialize() }
        guard case .storage(let failure)? = error else {
            Issue.record("expected .storage, got \(String(describing: error))")
            return
        }
        #expect(failure.kind == .diskFull)
        #expect(disk.contents(of: Self.path) == nil)
        disk.clearFaults()
        #expect(try settings.materialize())
    }

    @Test(.failureMode("design/18", "the file cannot be written when the app materializes it"))
    func aWriteOfUnknownDurabilityIsReportedAndTheFileIsThere() throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        disk.inject(EIO, on: .syncDirectory)
        let error = #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.materialize() }
        guard case .durabilityUnknown? = error else {
            Issue.record("expected .durabilityUnknown, got \(String(describing: error))")
            return
        }
        #expect(HandEditedTests.text(disk) != nil, "the file is there")
        disk.clearFaults()
        #expect(try !settings.materialize(), "and a later call finds it")
    }

    @Test func anAppOwnedStoreMaterializesItsEnvelopedFileToo() throws {
        let disk = try HandEditedTests.disk()
        let settings = try SettingsStore.open(at: "/d/prefs.json", schema: Prefs.schema, fileSystem: disk)
        #expect(try settings.materialize())
        #expect(try !settings.materialize())
        let reopened = try SettingsStore.open(at: "/d/prefs.json", schema: Prefs.schema, fileSystem: disk)
        #expect(reopened.source == .file)
        #expect(reopened.value == Prefs())
    }

    // MARK: Replacing an unusable file

    @Test(.failureMode("design/18", "an app replaces an unusable hand-edited file"))
    func theBrokenFileIsCopiedBeforeItIsReplacedAndTheReplacementIsPublished() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.garbage, on: disk)
        let events = RecordingInstrumentation()
        let settings = try Self.open(disk)
        #expect(settings.fileProblem != nil)

        let copy = try await withAmbient({ $0.instrumentation = events }) {
            try settings.replaceUnusableFile(with: LodePrefs(lode: "fresh"))
        }
        #expect(copy == "/d/lodestar.json.broken-1")
        #expect(HandEditedTests.text(disk, at: copy) == Self.garbage, "the person's bytes, as they were")
        #expect(try disk.permissions(of: copy) == 0o600)
        #expect(HandEditedTests.text(disk) == "{\n  \"$schema\": \"lodestar-schema.json\",\n  \"version\": 2,\n  \"lode\": \"fresh\"\n}\n")
        #expect(settings.value == LodePrefs(lode: "fresh"))
        #expect(settings.fileProblem == nil)
        #expect(settings.source == .file)
        #expect(settings.issues.isEmpty)
        #expect(events.events(named: "settings.replaced").first?["copy"]?.description == copy)
        #expect(try Self.open(disk).value == LodePrefs(lode: "fresh"))
        // An ordinary update works again.
        try settings.update { $0.speed = 900 }
    }

    @Test(.failureMode("design/18", "an app replaces an unusable hand-edited file"))
    func theCopyIsNumberedAfterTheOnesThere() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place("first", on: disk, at: Self.path + ".broken-1")
        try HandEditedTests.place("seventh", on: disk, at: Self.path + ".broken-7")
        try HandEditedTests.place("not a number", on: disk, at: Self.path + ".broken-x")
        try HandEditedTests.place(Self.garbage, on: disk)
        let settings = try Self.open(disk)
        #expect(try settings.replaceUnusableFile(with: LodePrefs()) == Self.path + ".broken-8")
        #expect(HandEditedTests.text(disk, at: Self.path + ".broken-7") == "seventh", "earlier copies are never touched")
    }

    @Test(.failureMode("design/18", "an app replaces an unusable hand-edited file"))
    func aCopyPathTheCallerGivesIsUsedAndNeverWrittenOverAFile() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.garbage, on: disk)
        let settings = try Self.open(disk)
        try HandEditedTests.place("an earlier copy of somebody's work", on: disk, at: "/d/keep.json")
        let error = #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) {
            try settings.replaceUnusableFile(with: LodePrefs(), keepingCopyAt: "/d/keep.json")
        }
        guard case .backupExists("/d/keep.json")? = error else {
            Issue.record("expected .backupExists, got \(String(describing: error))")
            return
        }
        #expect(HandEditedTests.text(disk, at: "/d/keep.json") == "an earlier copy of somebody's work")
        #expect(HandEditedTests.text(disk) == Self.garbage, "and the broken file is as it was")

        let copy = try settings.replaceUnusableFile(with: LodePrefs(), keepingCopyAt: "/d/mine.json")
        #expect(copy == "/d/mine.json")
        #expect(HandEditedTests.text(disk, at: "/d/mine.json") == Self.garbage)
    }

    @Test(.failureMode("design/18", "an app replaces a hand-edited file that can be read"))
    func aFileThatHasBeenFixedSinceTheAppLookedIsNotReplaced() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.garbage, on: disk)
        let settings = try Self.open(disk)
        #expect(settings.fileProblem != nil, "the app's last look: broken")
        let fixed = #"{"version": 2, "speed": 700}"#
        try HandEditedTests.place(fixed, on: disk)   // the person fixed it, and the app has not reloaded

        let error = #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) { try settings.replaceUnusableFile(with: LodePrefs()) }
        guard case .fileIsUsable? = error else {
            Issue.record("expected .fileIsUsable, got \(String(describing: error))")
            return
        }
        #expect(HandEditedTests.text(disk) == fixed)
        try HandEditedTests.expectNothingBesideTheFile(disk)
        #expect(try disk.list(directory: "/d").allSatisfy { !$0.contains(".broken") }, "no copy of a file that was fine")
        #expect(settings.value.speed == 700, "the fix is adopted, as an update would")
        #expect(settings.fileProblem == nil)
    }

    @Test(.failureMode("design/18", "an app replaces a hand-edited file that can be read"))
    func aMissingFileAndAFileThatIsOnlyNewerAreNotReplacedEither() throws {
        let missing = try HandEditedTests.disk()
        let settings = try Self.open(missing)
        #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) { try settings.replaceUnusableFile(with: LodePrefs()) }
        #expect(missing.contents(of: Self.path) == nil)

        let newer = try HandEditedTests.disk()
        let text = #"{"version": 9, "speed": 700}"#
        try HandEditedTests.place(text, on: newer)
        let reader = try Self.open(newer)
        #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) { try reader.replaceUnusableFile(with: LodePrefs()) }
        #expect(HandEditedTests.text(newer) == text, "a newer app's file is never overwritten")
    }

    @Test(.failureMode("design/18", "an app replaces an unusable hand-edited file"))
    func aReplacementTheSchemaRefusesChangesNothing() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.garbage, on: disk)
        let settings = try Self.open(disk)
        let error = #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) {
            try settings.replaceUnusableFile(with: LodePrefs(speed: 5))
        }
        guard case .invalid(let issues)? = error else {
            Issue.record("expected .invalid, got \(String(describing: error))")
            return
        }
        #expect(!issues.isEmpty)
        #expect(HandEditedTests.text(disk) == Self.garbage)
        #expect(try disk.list(directory: "/d").allSatisfy { !$0.contains(".broken") }, "no copy: nothing was done")
    }

    @Test(.failureMode("design/18", "an app replaces an unusable hand-edited file"))
    func aCopyThatCannotBeWrittenLeavesTheBrokenFileAndWritesNothingOver() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.garbage, on: disk)
        let settings = try Self.open(disk)
        disk.inject(ENOSPC, on: .write)
        let error = #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) { try settings.replaceUnusableFile(with: LodePrefs()) }
        guard case .copyFailed(let failure)? = error else {
            Issue.record("expected .copyFailed, got \(String(describing: error))")
            return
        }
        #expect(failure.kind == .diskFull)
        #expect(HandEditedTests.text(disk) == Self.garbage, "the copy came first, so nothing was replaced")
        #expect(settings.fileProblem != nil)
    }

    @Test(.failureMode("design/18", "an app replaces an unusable hand-edited file"))
    func aReplacementThatCannotBeWrittenLeavesTheBrokenFileAndTheCopyBesideIt() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.garbage, on: disk)
        let settings = try Self.open(disk)
        // The copy is written first (its writes succeed); the replacement's fail.
        disk.inject(ENOSPC, on: .write, skipping: 1)
        let error = #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) { try settings.replaceUnusableFile(with: LodePrefs()) }
        guard case .storage(let failure, let copy)? = error else {
            Issue.record("expected .storage, got \(String(describing: error))")
            return
        }
        #expect(failure.kind == .diskFull)
        #expect(HandEditedTests.text(disk) == Self.garbage)
        #expect(HandEditedTests.text(disk, at: copy) == Self.garbage)
        disk.clearFaults()
        #expect(try settings.replaceUnusableFile(with: LodePrefs()) == Self.path + ".broken-2", "and trying again is safe")
    }

    @Test(.failureMode("design/18", "an app replaces an unusable hand-edited file"))
    func aReplacementOfUnknownDurabilityIsPublishedAndSaysWhereTheCopyIs() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.garbage, on: disk)
        let settings = try Self.open(disk)
        // The copy's directory sync succeeds, the replacement's fails.
        disk.inject(EIO, on: .syncDirectory, skipping: 1)
        let error = #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) {
            try settings.replaceUnusableFile(with: LodePrefs(lode: "fresh"))
        }
        guard case .durabilityUnknown(_, let copy)? = error else {
            Issue.record("expected .durabilityUnknown, got \(String(describing: error))")
            return
        }
        #expect(HandEditedTests.text(disk, at: copy) == Self.garbage)
        #expect(settings.value == LodePrefs(lode: "fresh"), "the file holds it, so memory does")
        #expect(settings.fileProblem == nil)
    }

    @Test(.failureMode("design/18", "another process holds the lock on a hand-edited file"))
    func replacingDoesNotWaitForTheLockAndTouchesNothingWhileItIsHeld() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.garbage, on: disk)
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let settings = try Self.open(disk)
        let error = #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) { try settings.replaceUnusableFile(with: LodePrefs()) }
        guard case .busy? = error else {
            Issue.record("expected .busy, got \(String(describing: error))")
            return
        }
        #expect(HandEditedTests.text(disk) == Self.garbage)
        #expect(try disk.list(directory: "/d").allSatisfy { !$0.contains(".broken") })
        try tool.release()
    }

    @Test func anAppOwnedStoreHasNothingOfAPersonsToReplace() throws {
        let disk = try HandEditedTests.disk()
        let settings = try SettingsStore.open(at: "/d/prefs.json", schema: Prefs.schema, fileSystem: disk)
        let error = #expect(throws: SettingsStore<Prefs>.ReplaceError.self) { try settings.replaceUnusableFile(with: Prefs()) }
        guard case .notHandEdited? = error else {
            Issue.record("expected .notHandEdited, got \(String(describing: error))")
            return
        }
    }

    @Test(.failureMode("design/18", "an app replaces an unusable hand-edited file"))
    func aCrashAtAnyPointLeavesTheBrokenFileOrTheNewOneAndNeverTheNewOneWithoutTheCopy() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.garbage, on: disk)
        disk.settle()
        let settings = try Self.open(disk)
        let start = disk.operationCount
        try settings.replaceUnusableFile(with: LodePrefs(lode: "fresh"), keepingCopyAt: "/d/copy.json")
        var images = 0
        var replaced = 0
        for point in start...disk.operationCount {
            for image in disk.crashImages(afterOperation: point, samples: 8, seed: UInt64(point)) {
                images += 1
                let file = image.fileSystem.contents(of: Self.path).map { String(decoding: $0, as: UTF8.self) }
                let copy = image.fileSystem.contents(of: "/d/copy.json").map { String(decoding: $0, as: UTF8.self) }
                if file == Self.garbage { continue }   // not replaced yet: the person's file, whole
                replaced += 1
                #expect(file?.contains("\"fresh\"") == true, "crash after \(point): the file is the new one or the old, never torn: \(String(describing: file))")
                #expect(copy == Self.garbage, "crash after \(point): the new file is never there without the person's file kept: \(image.description)")
            }
        }
        #expect(images > 5)
        #expect(replaced > 0, "the crashes after the rename are checked too")
    }
}
