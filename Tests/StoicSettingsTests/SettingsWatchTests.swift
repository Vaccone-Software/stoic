import Foundation
import Observation
import Stoic
import StoicJSON
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// The watcher on a simulated disk, whose handler is called by the writer
/// that changed the file, and a test clock: nothing waits for real time.
@Suite("Settings store: watching the file")
struct SettingsWatchTests {
    static let path = HandEditedTests.path

    /// An editor that saved by rename: the file as it now is.
    static func edit(_ speed: Int, on disk: SimulatedFileSystem) throws {
        try HandEditedTests.place(#"{"version": 2, "speed": \#(speed)}"#, on: disk)
    }

    @Test(
        .failureMode("design/18", "several changes arrive in a burst"),
        .failureMode("design/18", "the hand-edited file is edited while the app runs"),
        .timeLimit(.minutes(1))
    )
    func aBurstOfChangesIsOneReloadOnceTheFileHasBeenQuietForTheDebounce() async throws {
        let base = try HandEditedTests.disk()
        try Self.edit(700, on: base)
        let disk = CountingFileSystem(base, counting: Self.path)
        let events = RecordingInstrumentation()
        let clock = TestClock()
        try await withTestAmbient(clock: clock, events: events) {
            let settings = try HandEditedTests.open(disk)
            let watch = try settings.watch(debounce: .milliseconds(300))
            let baseline = disk.readCount

            // An editor saving in steps, over 200 ms of virtual time.
            for step in 1...5 {
                try Self.edit(700 + step, on: base)
                if step == 1 { await clock.waitForSleepers(count: 1) }   // the watcher noticed, and waits
                if step < 5 { await clock.advance(by: .milliseconds(50)) }
            }
            #expect(disk.readCount == baseline, "nothing has been read yet")
            #expect(settings.value.speed == 700)

            await clock.advance(by: .milliseconds(100))   // 300 ms since the first change, 100 since the last
            await clock.waitForSleepers(count: 1)         // it looked again, and waits for the rest of the quiet
            #expect(disk.readCount == baseline)
            await clock.advance(by: .milliseconds(199))
            #expect(disk.readCount == baseline, "one millisecond short of the quiet")
            await clock.advance(by: .milliseconds(1))

            await waitUntil(settings) { settings.value.speed == 705 }
            #expect(disk.readCount == baseline + 1, "one reload for the whole burst")
            #expect(events.events(named: "settings.reloaded").count == 1)
            watch.stop()
        }
    }

    @Test(.failureMode("design/18", "the hand-edited file does not exist yet"), .timeLimit(.minutes(1)))
    func aFileThatDoesNotExistYetIsPickedUpWhenItIsCreated() async throws {
        let base = try HandEditedTests.disk()
        let disk = CountingFileSystem(base, counting: Self.path)
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let settings = try HandEditedTests.open(disk)
            #expect(settings.source == .defaults(.missing))
            let watch = try settings.watch()
            try Self.edit(900, on: base)
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(300))
            await waitUntil(settings) { settings.value.speed == 900 }
            #expect(settings.source == .file)
            watch.stop()
        }
    }

    @Test(.failureMode("design/18", "the store's own write is reported by the watcher"), .timeLimit(.minutes(1)))
    func theStoresOwnWriteIsReportedByTheWatcherAndFindsNothingChanged() async throws {
        let base = try HandEditedTests.disk()
        let disk = CountingFileSystem(base, counting: Self.path)
        let events = RecordingInstrumentation()
        let clock = TestClock()
        try await withTestAmbient(clock: clock, events: events) {
            let settings = try HandEditedTests.open(disk)
            let watch = try settings.watch()
            try settings.update { $0.speed = 800 }
            let baseline = disk.readCount
            let loads = events.events(named: "settings.loaded").count
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(300))
            while disk.readCount == baseline { await Task.yield() }   // the reload ran, and read the file
            #expect(settings.value.speed == 800)
            #expect(events.events(named: "settings.reloaded").isEmpty, "and published nothing")
            #expect(events.events(named: "settings.loaded").count == loads)
            watch.stop()
        }
    }

    @Test(.failureMode("design/18", "the hand-edited file is edited while the app runs"), .timeLimit(.minutes(1)))
    func aHalfSavedFileIsAProblemUntilTheNextSaveFixesIt() async throws {
        let base = try HandEditedTests.disk()
        try Self.edit(700, on: base)
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let settings = try HandEditedTests.open(base)
            let watch = try settings.watch()
            try HandEditedTests.place("{\"version\": 2, \"speed\": ", on: base)
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(300))
            await waitUntil(settings) { settings.fileProblem != nil }
            #expect(settings.value.speed == 700, "the last good value stands")

            try Self.edit(800, on: base)
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(300))
            await waitUntil(settings) { settings.value.speed == 800 }
            #expect(settings.fileProblem == nil)
            watch.stop()
        }
    }

    @Test(.failureMode("design/18", "the watch is stopped or dropped"), .timeLimit(.minutes(1)))
    func aStoppedWatchReloadsNothingMore() async throws {
        let base = try HandEditedTests.disk()
        try Self.edit(700, on: base)
        let disk = CountingFileSystem(base, counting: Self.path)
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let settings = try HandEditedTests.open(disk)
            let stopped = try settings.watch()
            let dropped = try settings.watch()
            stopped.stop()
            stopped.stop()   // harmless twice
            _ = dropped
            let baseline = disk.readCount
            do {
                let transient = try settings.watch()
                _ = transient
            }   // dropped: ends with its last reference
            try Self.edit(900, on: base)
            await clock.waitForSleepers(count: 1)   // the one watch still running
            await clock.advance(by: .milliseconds(300))
            await waitUntil(settings) { settings.value.speed == 900 }
            #expect(disk.readCount == baseline + 1, "reloaded once, by the one watch that was left")
            dropped.stop()
        }
    }

    @Test(.failureMode("design/18", "the watch cannot start"))
    func aWatchThatCannotStartThrows() throws {
        let missing = SimulatedFileSystem()
        let settings = try SettingsStore.open(
            at: "/nowhere/lodestar.json", schema: LodePrefs.schema, format: .handEdited, fileSystem: missing)
        let error = #expect(throws: StoreError.self) { try settings.watch() }
        #expect(error?.kind == .notFound)

        let disk = try HandEditedTests.disk()
        let ok = try HandEditedTests.open(disk)
        let invalid = #expect(throws: StoreError.self) { try ok.watch(debounce: .zero) }
        #expect(invalid?.kind == .invalidArgument)
    }

    @Test func aWatchDoesNotKeepTheStoreAlive() throws {
        let disk = try HandEditedTests.disk()
        let watch: SettingsWatch
        weak var store: SettingsStore<LodePrefs>?
        do {
            let settings = try HandEditedTests.open(disk)
            store = settings
            watch = try settings.watch()
        }
        #expect(store == nil)
        watch.stop()
    }
}

/// The real file system: kqueue on Apple platforms, inotify on Linux. Each
/// step waits on the store's own value (observation), with no fixed sleep and
/// the test's time limit as the only bound.
@Suite("Settings store: watching the file (real file system)")
struct RealSettingsWatchTests {
    @Test(.failureMode("design/18", "the hand-edited file is edited while the app runs"), .timeLimit(.minutes(1)))
    func aPersonsEditsAreSeenWhetherTheEditorCreatesWritesInPlaceOrSavesByRename() async throws {
        let directory = NSTemporaryDirectory() + "stoic-settings-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/lodestar.json"

        let settings = try SettingsStore.open(at: path, schema: LodePrefs.schema, format: .handEdited)
        #expect(settings.source == .defaults(.missing))
        let watch = try settings.watch(debounce: .milliseconds(20))

        // The file is created by something that is not the store.
        try #"{"version": 2, "speed": 700}"#.write(toFile: path, atomically: false, encoding: .utf8)
        await waitUntil(settings) { settings.value.speed == 700 }

        // An editor that truncates and writes in place.
        try "{\n  // by hand\n  \"version\": 2,\n  \"speed\": 800\n}\n".write(toFile: path, atomically: false, encoding: .utf8)
        await waitUntil(settings) { settings.value.speed == 800 }

        // An editor that writes a new file and renames it over the old.
        try #"{"version": 2, "speed": 900}"#.write(toFile: path, atomically: true, encoding: .utf8)
        await waitUntil(settings) { settings.value.speed == 900 }

        // The store's own update replaces the file too; the watch follows it,
        // and the next edit is still seen.
        try settings.update { $0.lode = "mine" }
        try #"{"version": 2, "speed": 1000, "lode": "mine"}"#.write(toFile: path, atomically: false, encoding: .utf8)
        await waitUntil(settings) { settings.value.speed == 1000 }
        #expect(settings.value.lode == "mine")

        // Garbage is a problem, and fixing it clears it.
        try "{ nope".write(toFile: path, atomically: false, encoding: .utf8)
        await waitUntil(settings) { settings.fileProblem != nil }
        #expect(settings.value.speed == 1000)
        try #"{"version": 2, "speed": 1100}"#.write(toFile: path, atomically: false, encoding: .utf8)
        await waitUntil(settings) { settings.fileProblem == nil && settings.value.speed == 1100 }
        watch.stop()
    }
}
