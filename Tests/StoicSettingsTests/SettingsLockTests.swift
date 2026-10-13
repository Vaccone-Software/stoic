import Stoic
@testable import StoicSettings
import StoicStore
import StoicTesting
import Testing

@Suite("Settings store: cross-process lock")
struct SettingsLockTests {
    static let path = "/d/prefs.json"
    static let locked = SettingsStore<Prefs>.Options(crossProcessLock: true)

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    static func open(_ disk: SimulatedFileSystem, options: SettingsStore<Prefs>.Options = locked) throws -> SettingsStore<Prefs> {
        try SettingsStore.open(at: path, schema: Prefs.schema, fileSystem: disk, options: options)
    }

    @Test(.failureMode("design/15", "settings are opened with `crossProcessLock` while another holds them"))
    func aSecondStoreOnTheSameFileIsBusyAndWritesNothing() throws {
        let disk = try Self.disk()
        let first = try Self.open(disk)
        try first.update { $0.speed = 900 }
        let before = disk.contents(of: Self.path)

        let error = #expect(throws: StoreError.self) { try Self.open(disk) }
        #expect(error?.kind == .busy)
        #expect(disk.contents(of: Self.path) == before, "the refused open wrote nothing")
        #expect(first.value.speed == 900)
    }

    @Test(.failureMode("design/15", "the holder dies without releasing"))
    func theLockGoesWithTheStore() throws {
        let disk = try Self.disk()
        do {
            let doomed = try Self.open(disk)
            try doomed.update { $0.speed = 700 }
        }
        #expect(try Self.open(disk).value.speed == 700)
    }

    @Test func theLockIsOptIn() throws {
        let disk = try Self.disk()
        let first = try Self.open(disk, options: .init())
        let second = try Self.open(disk, options: .init())
        _ = (first, second)
        #expect(disk.contents(of: Self.path + ".lock") == nil)
    }

    @Test(.failureMode("design/15", "settings are opened with `crossProcessLock` while another holds them"), .timeLimit(.minutes(1)))
    func openCanWaitForTheOtherProcessToFinish() async throws {
        let disk = try Self.disk()
        var first: SettingsStore<Prefs>? = try Self.open(disk)
        try first?.update { $0.speed = 800 }
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await SettingsStore.open(
                    at: Self.path, schema: Prefs.schema, fileSystem: disk, options: Self.locked, lockTimeout: .seconds(5))
            }
        }
        await clock.waitForSleepers(count: 1)
        first = nil   // the other "process" lets go
        await clock.advance(by: .milliseconds(25))
        let second = try await task.value
        #expect(second.value.speed == 800)
    }

    @Test(.failureMode("design/15", "`acquire` times out"), .timeLimit(.minutes(1)))
    func openGivesUpAtTheTimeout() async throws {
        let disk = try Self.disk()
        let first = try Self.open(disk)
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await SettingsStore.open(
                    at: Self.path, schema: Prefs.schema, fileSystem: disk, options: Self.locked, lockTimeout: .milliseconds(30))
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        do {
            _ = try await task.value
            Issue.record("opened a store another holds")
        } catch {
            #expect((error as? PolicyError<StoreError>)?.rejection?.reason == .deadlineExceeded)
        }
        _ = first
    }
}
