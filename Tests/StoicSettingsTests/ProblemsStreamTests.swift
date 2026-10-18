import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Synchronization
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads `count` problem changes from a stream (or all of them, if it ends first), on a task of its own.
func collectProblems(_ stream: AsyncStream<SettingsProblemChange>, count: Int) -> Task<[SettingsProblemChange], Never> {
    Task {
        var all: [SettingsProblemChange] = []
        guard count > 0 else { return all }
        for await change in stream {
            all.append(change)
            if all.count == count { break }
        }
        return all
    }
}

/// How an app learns that its file stopped parsing and parses again, without Observation.
///
/// A test that says "and nothing else" ends with a sentinel, as the changes' do: one more
/// transition, which must be the next the stream holds.
@Suite("Settings store: problems with the file")
struct ProblemsStreamTests {
    static let good = #"{"version": 2, "speed": 700}"#
    static let better = #"{"version": 2, "speed": 800}"#

    static func open(_ disk: SimulatedFileSystem, file text: String? = good) throws -> SettingsStore<LodePrefs> {
        if let text { try HandEditedTests.place(text, on: disk) }
        return try HandEditedTests.open(disk)
    }

    @Test(.failureMode("design/18", "the file's problem changes"), .timeLimit(.minutes(1)))
    func aFileThatStopsParsingIsAnnouncedBeforeTheReloadReturnsAndOneThatParsesAgainEndsIt() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        var problems = settings.problems().makeAsyncIterator()

        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        try settings.reload()
        // Announced by the time the reload has returned: this does not wait.
        let began = try #require(await problems.next())
        #expect(began.began)
        #expect(!began.ended)
        #expect(began.old == nil)
        #expect(began.new == settings.fileProblem)
        #expect(began.cause == .reload)
        #expect(began.new?.location?.line == 3, "with the line the app would show")

        try HandEditedTests.place(Self.better, on: disk)
        try settings.reload()
        let ended = try #require(await problems.next())
        #expect(ended.ended)
        #expect(!ended.began)
        #expect(ended.old == began.new)
        #expect(ended.new == nil)
        #expect(ended.cause == .reload)
    }

    @Test(.failureMode("design/18", "the file's problem changes"), .timeLimit(.minutes(1)))
    func theSameProblemAgainAndTheFileAsItWasAreNoChange() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        let collector = collectProblems(settings.problems(), count: 2)
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        try settings.reload()
        try HandEditedTests.place(HandEditedTests.garbage + " ", on: disk)   // the person saves the same typo, with a space more
        try settings.reload()
        try settings.reload()                                                    // and the file as the store last saw it
        try HandEditedTests.place(Self.good, on: disk)
        try settings.reload()                                                    // the sentinel: fixed
        let changes = await collector.value
        #expect(changes.map(\.began) == [true, false])
        #expect(changes[1].ended, "the next after the first is the fix, so nothing was announced in between")
    }

    @Test(.failureMode("design/18", "the file's problem changes"), .timeLimit(.minutes(1)))
    func aProblemThatMovesIsAChangeWithBothSidesAndIsNeitherBeganNorEnded() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk, file: HandEditedTests.garbage)
        #expect(settings.fileProblem != nil, "the state it opened in: read it, then listen")
        let collector = collectProblems(settings.problems(), count: 1)
        try HandEditedTests.place("{\n\n\n\n  \"speed\": ,\n}\n", on: disk)
        try settings.reload()
        let change = try #require(await collector.value.first)
        #expect(!change.began && !change.ended)
        #expect(change.old?.location?.line == 3)
        #expect(change.new?.location?.line == 5)
    }

    @Test(.failureMode("design/18", "the file's problem changes"), .timeLimit(.minutes(1)))
    func anUpdateThatFindsTheFileBrokenIsRefusedAndTheStreamHearsOfIt() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        let collector = collectProblems(settings.problems(), count: 1)
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.update { $0.speed = 900 } }
        let change = try #require(await collector.value.first)
        #expect(change.began)
        #expect(change.cause == .reload, "found by the update's own read of the file")
    }

    @Test(.failureMode("design/18", "the file's problem changes"), .timeLimit(.minutes(1)))
    func replacingTheUnusableFileEndsTheProblemWithTheCauseReset() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk, file: HandEditedTests.garbage)
        let collector = collectProblems(settings.problems(), count: 1)
        try settings.replaceUnusableFile(with: LodePrefs(speed: 900))
        let change = try #require(await collector.value.first)
        #expect(change.ended)
        #expect(change.cause == .reset)
        #expect(settings.fileProblem == nil)
    }

    @Test(.failureMode("design/18", "the file's problem changes"), .timeLimit(.minutes(1)))
    func aFileThatIsDeletedWhileBrokenEndsTheProblem() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk, file: HandEditedTests.garbage)
        let collector = collectProblems(settings.problems(), count: 1)
        try disk.remove(HandEditedTests.path)
        try settings.reload()
        #expect(await collector.value.first?.ended == true)
        #expect(settings.source == .defaults(.missing))
    }

    @Test(.failureMode("design/18", "the file's problem changes"), .timeLimit(.minutes(1)))
    func aFixThatChangesTheValueIsOneChangeOnEachStream() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        let problems = collectProblems(settings.problems(), count: 2)
        let values = collect(settings.changes(), count: 1)
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        try settings.reload()
        try HandEditedTests.place(Self.better, on: disk)
        try settings.reload()
        #expect(await problems.value.map(\.began) == [true, false])
        #expect(await values.value == [LodeChange(old: LodePrefs(speed: 700), new: LodePrefs(speed: 800), cause: .reload)],
                "the broken file was no change of the value; the fix was one")
    }

    @Test(.failureMode("design/18", "the file's problem changes"), .timeLimit(.minutes(1)))
    func anUnreadableFileIsAProblemToo() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        let collector = collectProblems(settings.problems(), count: 2)
        disk.inject(EACCES, on: .read, count: 100)
        try settings.reload()
        disk.clearFaults()
        try settings.reload()
        let changes = await collector.value
        guard case .unreadable? = changes.first?.new else {
            Issue.record("expected an unreadable file, got \(String(describing: changes.first))")
            return
        }
        #expect(changes.last?.ended == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func eachStreamSeesOnlyWhatWasCommittedAfterItWasMade() async throws {
        let disk = try HandEditedTests.disk()
        let settings = try Self.open(disk)
        let early = collectProblems(settings.problems(), count: 2)
        try HandEditedTests.place(HandEditedTests.garbage, on: disk)
        try settings.reload()
        let late = collectProblems(settings.problems(), count: 1)
        try HandEditedTests.place(Self.good, on: disk)
        try settings.reload()
        #expect(await early.value.map(\.began) == [true, false])
        #expect(await late.value.map(\.ended) == [true])
    }

    @Test(.failureMode("design/18", "a reader of the changes falls behind"), .timeLimit(.minutes(1)))
    func aReaderThatFallsBehindLosesTheOldestAndTheDropIsReported() async throws {
        let disk = try HandEditedTests.disk()
        let events = RecordingInstrumentation()
        let settings = try Self.open(disk)
        let stream = settings.problems(buffering: 1)
        try await withAmbient({ $0.instrumentation = events }) {
            try HandEditedTests.place(HandEditedTests.garbage, on: disk)
            try settings.reload()
            try HandEditedTests.place(Self.good, on: disk)
            try settings.reload()
        }
        var changes = stream.makeAsyncIterator()
        #expect(await changes.next()?.ended == true, "the newest only")
        #expect(events.events(named: "settings.change_dropped").map { $0["dropped"]?.description } == ["1"])
    }

    @Test(.timeLimit(.minutes(1))) func aStreamThatEndsIsForgottenAndAStoreThatGoesEndsItsStreams() async throws {
        let disk = try HandEditedTests.disk()
        var settings: SettingsStore<LodePrefs>? = try Self.open(disk)
        let first = try #require(settings).problems()
        do {
            let store = try #require(settings)
            #expect(store.listeners.withLock { $0.problemContinuations.count } == 1)
            let reader = Task { for await _ in store.problems() {} }
            while store.listeners.withLock({ $0.problemContinuations.count }) < 2 { await Task.yield() }
            reader.cancel()
            await reader.value
            #expect(store.listeners.withLock { $0.problemContinuations.count } == 1, "the cancelled reader's stream is gone")
        }
        let ending = collectProblems(first, count: 10)
        settings = nil
        #expect(await ending.value.isEmpty, "the store went, and its stream ended")
    }

    @Test(.timeLimit(.minutes(1))) func anAppOwnedStoreHasNoProblemToAnnounce() async throws {
        let disk = try HandEditedTests.disk()
        var settings: SettingsStore<Prefs>? = try SettingsStore.open(at: "/d/prefs.json", schema: Prefs.schema, fileSystem: disk)
        let collector = collectProblems(try #require(settings).problems(), count: 1)
        try #require(settings).update { $0.speed = 900 }
        try #require(settings).reload()
        settings = nil
        #expect(await collector.value.isEmpty)
    }

    @Test(.failureMode("design/18", "the file's problem changes"), .timeLimit(.minutes(1)))
    func theWatchTellsTheStreamWhenTheFileBreaksAndWhenItIsFixed() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(Self.good, on: disk)
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            let settings = try HandEditedTests.open(disk)
            let collector = collectProblems(settings.problems(), count: 2)
            let watch = try settings.watch()
            try HandEditedTests.place(HandEditedTests.garbage, on: disk)
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(300))
            try HandEditedTests.place(Self.better, on: disk)
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(300))
            #expect(await collector.value.map(\.began) == [true, false])
            watch.stop()
        }
    }
}
