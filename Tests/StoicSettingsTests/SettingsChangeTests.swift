import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Synchronization
import Testing

typealias LodeChange = SettingsChange<LodePrefs>

/// Reads `count` changes from a stream (or all of them, if it ends first), on a task of its own.
func collect<V: Sendable & Equatable>(_ stream: AsyncStream<SettingsChange<V>>, count: Int) -> Task<[SettingsChange<V>], Never> {
    Task {
        var all: [SettingsChange<V>] = []
        guard count > 0 else { return all }
        for await change in stream {
            all.append(change)
            if all.count == count { break }
        }
        return all
    }
}

/// What a store tells an app that wants to know why its value changed, and what it was.
///
/// A test that says "and nothing else" ends with a *sentinel*: one more update, whose
/// change must be the next one the stream holds, so anything that was announced
/// before it and should not have been is in the way.
@Suite("Settings store: changes with their cause")
struct SettingsChangeTests {
    static let path = HandEditedTests.path

    static func open(_ disk: some FileSystem, options: SettingsStore<LodePrefs>.Options = .init()) throws -> SettingsStore<LodePrefs> {
        try HandEditedTests.open(disk, options: options)
    }

    /// The change the sentinel update makes from `value`.
    static func sentinel(after value: LodePrefs) -> LodeChange {
        var next = value
        next.lode = "sentinel"
        return LodeChange(old: value, new: next, cause: .update)
    }

    static func makeSentinel(_ settings: SettingsStore<LodePrefs>) throws {
        try settings.update { $0.lode = "sentinel" }
    }

    @Test(.failureMode("design/18", "the value of a store changes"), .timeLimit(.minutes(1)))
    func anUpdateIsOneChangeWithWhatItWasWhatItIsAndItsCauseAnnouncedBeforeItReturns() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        var changes = settings.changes().makeAsyncIterator()
        try settings.update { $0.speed = 900 }
        // Announced by the time the update has returned: this does not wait.
        let change = await changes.next()
        #expect(change == LodeChange(old: LodePrefs(), new: LodePrefs(speed: 900), cause: .update))
    }

    @Test(.failureMode("design/18", "the value of a store changes"), .timeLimit(.minutes(1)))
    func aWriteThatChangesNothingIsNoChangeAndNeitherIsAnIssuesOnlyChange() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        let collector = collect(settings.changes(), count: 1)
        try settings.update { $0.speed = 700 }                   // the value it has
        try settings.reload()                                     // the file as the store last saw it
        try HandEditedTests.place(#"{"version": 2, "speed": 700, "extra": 1}"#, on: disk)
        try settings.reload()                                     // the file changed; the value did not (an issue did)
        #expect(!settings.issues.isEmpty)
        try Self.makeSentinel(settings)
        #expect(await collector.value == [Self.sentinel(after: LodePrefs(speed: 700))])
    }

    @Test(.failureMode("design/18", "the value of a store changes"), .timeLimit(.minutes(1)))
    func aReloadThatFindsAnEditIsAChangeWithTheCauseReload() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        let collector = collect(settings.changes(), count: 2)
        try HandEditedTests.place(#"{"version": 2, "speed": 800, "lode": "tool"}"#, on: disk)
        try settings.reload()
        try Self.makeSentinel(settings)
        let edited = LodePrefs(lode: "tool", speed: 800)
        #expect(await collector.value == [
            LodeChange(old: LodePrefs(speed: 700), new: edited, cause: .reload),
            Self.sentinel(after: edited),
        ])
    }

    @Test(.failureMode("design/18", "an update finds the hand-edited file changed"), .timeLimit(.minutes(1)))
    func anUpdateThatFindsTheFileChangedIsTwoChangesTheEditsAndThenItsOwn() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        let collector = collect(settings.changes(), count: 2)
        try HandEditedTests.place(#"{"version": 2, "speed": 700, "lode": "tool"}"#, on: disk)   // the tool, a moment ago
        try settings.update { $0.hosts = ["app"] }
        let tool = LodePrefs(lode: "tool", speed: 700)
        #expect(await collector.value == [
            LodeChange(old: LodePrefs(speed: 700), new: tool, cause: .reload),
            LodeChange(old: tool, new: LodePrefs(lode: "tool", speed: 700, hosts: ["app"]), cause: .update),
        ], "what the person did, then what the app did, so a history can tell them apart")
    }

    @Test(.failureMode("design/18", "the store's own write is reported by the watcher"), .timeLimit(.minutes(1)))
    func theStoresOwnWriteThatTheWatcherReadsAgainIsNotASecondChange() async throws {
        let base = try HandEditedTests.disk()
        let disk = CountingFileSystem(base, counting: Self.path)
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let settings = try Self.open(disk)
            let collector = collect(settings.changes(), count: 2)
            let watch = try settings.watch()
            try settings.update { $0.speed = 800 }
            let baseline = disk.readCount
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(300))
            while disk.readCount == baseline { await Task.yield() }   // the watcher's reload ran, and read the file
            try settings.reload()                                      // serialised after it: it is over
            try Self.makeSentinel(settings)
            watch.stop()
            #expect(await collector.value == [
                LodeChange(old: LodePrefs(), new: LodePrefs(speed: 800), cause: .update),
                Self.sentinel(after: LodePrefs(speed: 800)),
            ], "one change for the edit; none for the watcher's reading of it")
        }
    }

    @Test(.failureMode("design/18", "the hand-edited file is edited while the app runs"), .timeLimit(.minutes(1)))
    func anEditMadeWhileTheAppRunsArrivesThroughTheWatchAsAReloadChange() async throws {
        let base = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: base)
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let settings = try Self.open(base)
            let collector = collect(settings.changes(), count: 1)
            let watch = try settings.watch()
            try HandEditedTests.place(#"{"version": 2, "speed": 850}"#, on: base)
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(300))
            #expect(await collector.value == [LodeChange(old: LodePrefs(speed: 700), new: LodePrefs(speed: 850), cause: .reload)])
            watch.stop()
        }
    }

    @Test(.failureMode("design/18", "an app replaces an unusable hand-edited file"), .timeLimit(.minutes(1)))
    func replacingAnUnusableFileIsAChangeWithTheCauseReset() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let settings = try Self.open(disk)
        let collector = collect(settings.changes(), count: 2)
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        try settings.reload()   // broken: the last good value stays, and no change
        try settings.replaceUnusableFile(with: LodePrefs(lode: "fresh"))
        try Self.makeSentinel(settings)
        #expect(await collector.value == [
            LodeChange(old: LodePrefs(speed: 700), new: LodePrefs(lode: "fresh"), cause: .reset),
            Self.sentinel(after: LodePrefs(lode: "fresh")),
        ])
    }

    @Test(.timeLimit(.minutes(1))) func materializingChangesNoValueSoItIsNoChange() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        let collector = collect(settings.changes(), count: 1)
        try settings.materialize()
        try Self.makeSentinel(settings)
        #expect(await collector.value == [Self.sentinel(after: LodePrefs())])
    }

    @Test(.failureMode("design/18", "the value of a store changes"), .timeLimit(.minutes(1)))
    func changesAreInTheOrderTheyWereCommittedAndEachOldIsThePreviousNew() async throws {
        // App-owned, so that the threads contend for the store's own serialisation and not for a file lock
        // that a blocking wait would poll in real time.
        let disk = try HandEditedTests.disk()
        let settings = try SettingsStore.open(at: "/d/prefs.json", schema: Prefs.schema, fileSystem: disk)
        let collector = collect(settings.changes(buffering: 1000), count: 120)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    for _ in 0..<20 { try settings.update { $0.speed += 1 } }
                }
            }
            try await group.waitForAll()
        }
        let all = await collector.value
        #expect(all.count == 120)
        #expect(all.map(\.new.speed) == Array(601...720), "every update, in order")
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.new == $1.old }, "a history with no gaps")
        #expect(all.allSatisfy { $0.cause == .update })
    }

    @Test(.timeLimit(.minutes(1)))
    func eachStreamSeesOnlyWhatWasCommittedAfterItWasMadeAndAllOfIt() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        try settings.update { $0.speed = 700 }
        let early = collect(settings.changes(), count: 2)
        try settings.update { $0.speed = 800 }
        let late = collect(settings.changes(), count: 1)
        try settings.update { $0.speed = 900 }
        #expect(await early.value.map(\.new.speed) == [800, 900])
        #expect(await late.value.map(\.new.speed) == [900])
    }

    @Test(.failureMode("design/18", "a reader of the changes falls behind"), .timeLimit(.minutes(1)))
    func aReaderThatFallsBehindLosesTheOldestAndTheDropIsReported() async throws {
        let disk = try HandEditedTests.disk()
        let events = RecordingInstrumentation()
        let settings = try Self.open(disk)
        let stream = settings.changes(buffering: 2)
        // Nobody reads while five updates are made.
        try await withAmbient({ $0.instrumentation = events }) {
            for speed in 701...705 { try settings.update { $0.speed = speed } }
        }
        var changes = stream.makeAsyncIterator()
        let first = await changes.next()
        let second = await changes.next()
        #expect([first?.new.speed, second?.new.speed] == [704, 705], "the newest two: the oldest were dropped")
        #expect(first?.old.speed == 703, "and the chain shows the gap: 704 was not preceded by what this one says it was")
        let dropped = events.events(named: "settings.change_dropped").map { $0["dropped"]?.description }
        #expect(dropped == ["1", "1", "1"], "each drop was reported: \(dropped)")
    }

    @Test(.timeLimit(.minutes(1))) func aStreamThatEndsIsForgottenAndAStoreThatGoesEndsItsStreams() async throws {
        let disk = try HandEditedTests.disk()
        var settings: SettingsStore<LodePrefs>? = try Self.open(disk)
        let first = try #require(settings).changes()
        do {
            let store = try #require(settings)
            #expect(store.listeners.withLock { $0.continuations.count } == 1)
            let reader = Task { for await _ in store.changes() {} }
            while store.listeners.withLock({ $0.continuations.count }) < 2 { await Task.yield() }
            reader.cancel()
            await reader.value
            #expect(store.listeners.withLock { $0.continuations.count } == 1, "the cancelled reader's stream is gone; the first stays")
        }
        let ending = collect(first, count: 10)
        settings = nil
        #expect(await ending.value.isEmpty, "the store went, and its stream ended")
    }

    @Test(.failureMode("design/18", "the value of a store changes"), .timeLimit(.minutes(1)))
    func anAppOwnedStoreTellsItsChangesToo() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try SettingsStore.open(at: "/d/prefs.json", schema: Prefs.schema, fileSystem: disk)
        let collector = collect(settings.changes(), count: 2)
        try settings.update { $0.speed = 900 }
        try settings.reload()   // the file as the store wrote it: the same value, no change
        try settings.update { $0.speed = 1000 }
        #expect(await collector.value == [
            SettingsChange(old: Prefs(), new: Prefs(speed: 900), cause: .update),
            SettingsChange(old: Prefs(speed: 900), new: Prefs(speed: 1000), cause: .update),
        ])
    }
}
