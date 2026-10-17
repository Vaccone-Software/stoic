import Stoic
import StoicJSON
import StoicSchema
@testable import StoicSettings
import StoicStore
import StoicTesting
import Synchronization
import Testing

/// Made-up time for a wait that blocks a thread: each pause advances it, and may
/// do something while "waiting" (the other writer lets go). Nothing sleeps.
final class FakeTime: Sendable {
    private struct State {
        var now = Duration.zero
        var pauses: [Duration] = []
    }

    private let state = Mutex(State())
    private let onPause: Mutex<(@Sendable (Int) -> Void)?> = Mutex(nil)

    var pauses: [Duration] { state.withLock { $0.pauses } }

    func whenPausing(_ action: @escaping @Sendable (Int) -> Void) {
        onPause.withLock { $0 = action }
    }

    var wait: BlockingWait {
        BlockingWait(
            now: { self.state.withLock { $0.now } },
            pause: { duration in
                let count = self.state.withLock { state -> Int in
                    state.now += duration
                    state.pauses.append(duration)
                    return state.pauses.count
                }
                self.onPause.withLock { $0 }?(count)
            })
    }
}

/// The synchronous update that waits for the other writer's lock by blocking its thread.
@Suite("Settings store: blocking update")
struct BlockingUpdateTests {
    static let path = HandEditedTests.path

    static func settings(
        _ disk: SimulatedFileSystem, time: FakeTime? = nil, options: HandEditedOptions = HandEditedOptions()
    ) throws -> SettingsStore<LodePrefs> {
        let settings = try HandEditedTests.open(disk, options: .init(handEdited: options))
        if let time { settings.blockingWait.withLock { $0 = time.wait } }
        return settings
    }

    @Test(.failureMode("design/18", "a synchronous update has to wait for the other writer's lock"))
    func itPollsEveryTwentyFiveMillisecondsAndUpdatesOnceTheOtherWriterLetsGo() throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)
        time.whenPausing { count in
            if count == 1 { try? HandEditedTests.place(#"{"version": 2, "speed": 700, "lode": "tool"}"#, on: disk) }   // the tool's edit
            if count == 3 { try? tool.release() }
        }

        let value = try settings.blockingUpdate { $0.hosts = ["app"] }
        #expect(time.pauses == Array(repeating: .milliseconds(25), count: 3), "three tries failed, the fourth took the lock")
        #expect(value == LodePrefs(lode: "tool", speed: 700, hosts: ["app"]), "applied to what the tool left: neither edit is lost")
        #expect(try HandEditedTests.open(disk).value == value)
    }

    @Test(.failureMode("design/18", "a synchronous update has to wait for the other writer's lock"))
    func itGivesUpAtTheTimeoutWithBusyHavingWaitedExactlyThatLongAndTouchesNothing() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let before = disk.contents(of: Self.path)
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let events = RecordingInstrumentation()
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)

        let error = await withAmbient({ $0.instrumentation = events }) {
            #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) {
                try settings.blockingUpdate(waitingUpTo: .milliseconds(110)) { $0.speed = 900 }
            }
        }
        guard case .busy? = error else {
            Issue.record("expected .busy, got \(String(describing: error))")
            return
        }
        #expect(time.pauses == [.milliseconds(25), .milliseconds(25), .milliseconds(25), .milliseconds(25), .milliseconds(10)],
                "the last pause is what is left of the wait, so it ends at the timeout and not after it")
        #expect(disk.contents(of: Self.path) == before)
        #expect(settings.value.speed == 700)
        #expect(events.events(named: "settings.busy").first?["waitMs"]?.description == "110")
        try tool.release()
    }

    @Test func aZeroWaitTriesOnceLikeUpdate() throws {
        let disk = try HandEditedTests.disk()
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.blockingUpdate(waitingUpTo: .zero) { $0.speed = 900 } }
        #expect(time.pauses.isEmpty)
        try tool.release()
        try settings.blockingUpdate(waitingUpTo: .zero) { $0.speed = 900 }
    }

    @Test func withoutAnArgumentItWaitsAsLongAsTheStoresLockTimeout() throws {
        let disk = try HandEditedTests.disk()
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time, options: HandEditedOptions(lockTimeout: .milliseconds(300)))
        #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) { try settings.blockingUpdate { $0.speed = 900 } }
        #expect(time.pauses.reduce(.zero, +) == .milliseconds(300))
        try tool.release()
    }

    @Test(.failureMode("design/18", "a synchronous update has to wait for the other writer's lock"), .timeLimit(.minutes(1)))
    func aCancelledTaskLeavesWithCancellationAndWritesNothing() async throws {
        let disk = try HandEditedTests.disk()
        try HandEditedTests.place(#"{"version": 2, "speed": 700}"#, on: disk)
        let before = disk.contents(of: Self.path)
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let time = FakeTime()
        let settings = try Self.settings(disk, time: time)
        // The task is cancelled while it waits (from inside the wait, so nothing races).
        time.whenPausing { _ in unsafe withUnsafeCurrentTask { task in unsafe task?.cancel() } }
        let task = Task { try settings.blockingUpdate { $0.speed = 900 } }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(time.pauses.count == 1, "it did not try again")
        #expect(disk.contents(of: Self.path) == before)
        try tool.release()

        // And one that was cancelled before it began does not take a free lock and write.
        let cancelled = Task { () throws -> LodePrefs in
            unsafe withUnsafeCurrentTask { task in unsafe task?.cancel() }
            return try settings.blockingUpdate { $0.speed = 900 }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(disk.contents(of: Self.path) == before)
    }

    @Test func anAppOwnedStoreHasNoOtherWriterAndUpdatesAtOnce() throws {
        let disk = try HandEditedTests.disk()
        let settings = try SettingsStore.open(at: "/d/prefs.json", schema: Prefs.schema, fileSystem: disk)
        let time = FakeTime()
        settings.blockingWait.withLock { $0 = time.wait }
        try settings.blockingUpdate { $0.speed = 900 }
        #expect(settings.value.speed == 900)
        #expect(time.pauses.isEmpty)
    }

    @Test(.failureMode("design/18", "the app holds the lock for life and the file is hand-edited"))
    func aStoreThatHoldsTheLockForLifeUsesItsOwnHoldAndDoesNotWait() throws {
        let disk = try HandEditedTests.disk()
        let options = SettingsStore<LodePrefs>.Options(crossProcessLock: true)
        let settings = try HandEditedTests.open(disk, options: options)
        let time = FakeTime()
        settings.blockingWait.withLock { $0 = time.wait }
        try settings.blockingUpdate { $0.speed = 900 }
        #expect(time.pauses.isEmpty)
        #expect(try HandEditedTests.open(disk).value.speed == 900)
    }

    /// The real wait, on the real monotonic clock: it ends at the timeout, not before and not long after.
    @Test(.failureMode("design/18", "a synchronous update has to wait for the other writer's lock"))
    func theRealWaitEndsAtTheTimeout() throws {
        let disk = try HandEditedTests.disk()
        let tool = FileLock(path: Self.path + ".lock", fileSystem: disk)
        try #require(try tool.tryAcquire())
        let settings = try Self.settings(disk)
        let clock = ContinuousClock()
        let waited = clock.measure {
            #expect(throws: SettingsStore<LodePrefs>.UpdateError.self) {
                try settings.blockingUpdate(waitingUpTo: .milliseconds(120)) { $0.speed = 900 }
            }
        }
        #expect(waited >= .milliseconds(120), "it waited the whole time: \(waited)")
        #expect(waited < .seconds(10), "and then stopped: \(waited)")
        try tool.release()
    }
}
