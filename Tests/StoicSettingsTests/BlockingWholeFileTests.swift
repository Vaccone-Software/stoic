import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// Materializing and replacing, when another process is writing at that moment.
@Suite("Settings store: blocking materialize and replace")
struct BlockingWholeFileTests {
    static let path = HandEditedTests.path

    static func settings(
        _ disk: SimulatedFileSystem, time: FakeTime? = nil, options: HandEditedOptions = HandEditedOptions()
    ) throws -> SettingsStore<LodePrefs> {
        try BlockingUpdateTests.settings(disk, time: time, options: options)
    }

    static func held(_ disk: SimulatedFileSystem) throws -> FileLock {
        let tool = FileLock(path: path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        return tool
    }

    // MARK: Materializing

    @Test(.failureMode("design/18", "a first launch or a reset has to wait for the other writer's lock"))
    func materializingPollsAndWritesTheFileOnceTheOtherWriterLetsGo() throws {
        let disk = try HandEditedTests.disk()
        let tool = try Self.held(disk)
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)
        time.whenPausing { count in if count == 2 { try? tool.release() } }

        #expect(try settings.blockingMaterialize())
        #expect(time.pauses == [.milliseconds(25), .milliseconds(25)], "two tries failed, the third took the lock")
        #expect(HandEditedTests.text(disk) == "{\n  \"version\": 2\n}\n")
        #expect(try disk.permissions(of: Self.path) == 0o600)
    }

    @Test(.failureMode("design/18", "a first launch or a reset has to wait for the other writer's lock"))
    func aFileTheOtherWriterMadeWhileItWaitedIsFoundThereAndNotWrittenOver() throws {
        let disk = try HandEditedTests.disk()
        let tool = try Self.held(disk)
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)
        time.whenPausing { count in
            if count == 1 {
                try? HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)
                try? tool.release()
            }
        }
        #expect(try !settings.blockingMaterialize(), "the tool's file is what is there")
        #expect(HandEditedTests.text(disk) == #"{"version": 2, "speed": 700}"#, "byte for byte")
    }

    @Test(.failureMode("design/18", "a first launch or a reset has to wait for the other writer's lock"))
    func materializingGivesUpAtTheTimeoutWithBusyAndWritesNothing() async throws {
        let disk = try HandEditedTests.disk()
        let tool = try Self.held(disk)
        let events = RecordingInstrumentation()
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)
        let error = await withAmbient({ $0.instrumentation = events }) {
            #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.blockingMaterialize(waitingUpTo: .milliseconds(60)) }
        }
        guard case .busy? = error else {
            Issue.record("expected .busy, got \(String(describing: error))")
            return
        }
        #expect(time.pauses == [.milliseconds(25), .milliseconds(25), .milliseconds(10)])
        #expect(disk.contents(of: Self.path) == nil, "nothing was written")
        #expect(events.events(named: "settings.busy").first?["waitMs"]?.description == "60")
        try tool.release()
    }

    @Test func aZeroWaitMaterializesLikeMaterializeAndWithoutAnArgumentWaitsTheStoresLockTimeout() throws {
        let disk = try HandEditedTests.disk()
        let tool = try Self.held(disk)
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time, options: HandEditedOptions(lockTimeout: .milliseconds(200)))
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.blockingMaterialize(waitingUpTo: .zero) }
        #expect(time.pauses.isEmpty)
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.blockingMaterialize() }
        #expect(time.pauses.reduce(.zero, +) == .milliseconds(200))
        try tool.release()
        #expect(try settings.blockingMaterialize(waitingUpTo: .zero))
    }

    @Test(.failureMode("design/18", "a first launch or a reset has to wait for the other writer's lock"), .timeLimit(.minutes(1)))
    func aCancelledTaskLeavesWithCancellationAndDoesNotMaterialize() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.settings(disk, time: FakeTime())
        let cancelled = Task { () throws -> Bool in
            unsafe withUnsafeCurrentTask { task in unsafe task?.cancel() }
            return try settings.blockingMaterialize()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(disk.contents(of: Self.path) == nil, "it did not take a free lock and write")
    }

    // MARK: Replacing

    @Test(.failureMode("design/18", "a first launch or a reset has to wait for the other writer's lock"))
    func replacingPollsAndThenDoesEveryStepOfTheReplacement() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        let tool = try Self.held(disk)
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)
        time.whenPausing { count in if count == 3 { try? tool.release() } }

        let copy = try settings.blockingReplaceUnusableFile(with: LodePrefs(speed: 900))
        #expect(time.pauses.count == 3)
        #expect(copy == Self.path + ".broken-1")
        #expect(HandEditedTests.text(disk, at: copy) == HandEditedTests.garbage, "the person's bytes, kept")
        #expect(try HandEditedTests.open(disk).value == LodePrefs(speed: 900))
        #expect(settings.fileProblem == nil)
    }

    @Test(.failureMode("design/18", "a first launch or a reset has to wait for the other writer's lock"))
    func replacingThatTimesOutIsBusyAndNothingWasReadCopiedOrWritten() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        let tool = try Self.held(disk)
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)

        let error = #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) {
            try settings.blockingReplaceUnusableFile(with: LodePrefs(), waitingUpTo: .milliseconds(50))
        }
        guard case .busy? = error else {
            Issue.record("expected .busy, got \(String(describing: error))")
            return
        }
        #expect(time.pauses == [.milliseconds(25), .milliseconds(25)])
        #expect(HandEditedTests.text(disk) == HandEditedTests.garbage)
        #expect(try disk.list(directory: "/d").allSatisfy { !$0.contains(".broken") }, "no copy")
        try tool.release()
    }

    @Test(.failureMode("design/18", "an update is given a source"), .timeLimit(.minutes(1)))
    func aResetCarriesTheSourceItWasGiven() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        let settings = try HandEditedTests.open(disk)
        let collector = collect(settings.changes(), count: 1)
        try settings.blockingReplaceUnusableFile(with: LodePrefs(speed: 900), source: "reset button")
        #expect(await collector.value == [LodeChange(old: LodePrefs(), new: LodePrefs(speed: 900), cause: .reset, source: "reset button")])
    }

    @Test func aFileThatIsUsableByTheTimeTheLockIsHeldIsNotReplaced() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        let tool = try Self.held(disk)
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)
        time.whenPausing { count in
            if count == 1 {
                try? HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)   // the person fixed it
                try? tool.release()
            }
        }
        let error = #expect(throws: SettingsStore<LodePrefs>.ReplaceError.self) {
            try settings.blockingReplaceUnusableFile(with: LodePrefs())
        }
        guard case .fileIsUsable? = error else {
            Issue.record("expected .fileIsUsable, got \(String(describing: error))")
            return
        }
        #expect(HandEditedTests.text(disk) == #"{"version": 2, "speed": 700}"#)
    }

    @Test func anAppOwnedStoreHasNoFileOfAPersonsToReplace() throws {
        let disk = try HandEditedTests.disk()
        let settings = try SettingsStore.open(at: "/d/prefs.json", schema: Prefs.schema, fileSystem: disk)
        let error = #expect(throws: SettingsStore<Prefs>.ReplaceError.self) {
            try settings.blockingReplaceUnusableFile(with: Prefs())
        }
        guard case .notHandEdited? = error else {
            Issue.record("expected .notHandEdited, got \(String(describing: error))")
            return
        }
    }

    @Test(.failureMode("design/18", "a first launch or a reset has to wait for the other writer's lock"), .timeLimit(.minutes(1)))
    func aCancelledTaskLeavesReplacingWithCancellationBeforeAnyCopy() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        let settings = try Self.settings(disk, time: FakeTime())
        let cancelled = Task { () throws -> String in
            unsafe withUnsafeCurrentTask { task in unsafe task?.cancel() }
            return try settings.blockingReplaceUnusableFile(with: LodePrefs())
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(HandEditedTests.text(disk) == HandEditedTests.garbage)
        #expect(try disk.list(directory: "/d").allSatisfy { !$0.contains(".broken") })
    }
}
