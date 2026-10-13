import Stoic
import StoicStore
import StoicTesting
import Testing

@Suite("LaunchGuard")
struct LaunchGuardTests {
    func makeGuard(_ fs: SimulatedFileSystem, limit: Int = 3, build: String? = nil, boot: String? = "boot-1") -> LaunchGuard {
        LaunchGuard(path: "/app/launch-guard", uncleanLimit: limit, build: build, bootSession: boot, file: AtomicFile(fileSystem: fs, options: .init(keepPrevious: true, checksFreeSpace: false)))
    }

    @Test func aFirstLaunchIsNormal() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        #expect(try makeGuard(fs).beginLaunch() == .normal)
    }

    @Test func consecutiveUncleanLaunchesTriggerSafeMode() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        // Three launches that crash before becoming stable…
        for _ in 0..<3 { _ = try makeGuard(fs).beginLaunch() }
        // …and the fourth is told to start in safe mode.
        #expect(try makeGuard(fs).beginLaunch() == .safeMode(uncleanLaunches: 3))
    }

    @Test func aStableLaunchResetsTheCount() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        for _ in 0..<2 { _ = try makeGuard(fs).beginLaunch() }
        let stable = makeGuard(fs)
        _ = try stable.beginLaunch()
        try stable.markStable()
        #expect(try makeGuard(fs).beginLaunch() == .normal)
    }

    @Test func aCleanExitIsNotACrash() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        for _ in 0..<5 {
            let launch = makeGuard(fs, limit: 1)
            #expect(try launch.beginLaunch() == .normal)
            try launch.markCleanExit()
        }
    }

    @Test func aCorruptStateFileIsNoHistory() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        let writer = AtomicFile(fileSystem: fs, options: .init(envelope: false, checksFreeSpace: false))
        try writer.write(Array("garbage".utf8), to: "/app/launch-guard")
        #expect(try makeGuard(fs).beginLaunch() == .normal)
    }

    @Test func stabilityCanBeDeclaredAfterADelay() async throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        let clock = TestClock()
        let launch = makeGuard(fs, limit: 1)
        _ = try launch.beginLaunch()
        let task = await withTestAmbient(clock: clock) { launch.markStable(after: .seconds(30)) }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(30))
        await task.value
        #expect(try makeGuard(fs, limit: 1).beginLaunch() == .normal)
    }

    @Test(.failureMode("design/15", "the app is backgrounded before the launch is stable")) func aLaunchEndedInTheBackgroundIsNotACrash() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        // The user swipes the app away, or the system reclaims it, before it
        // has run long enough to be called stable — over and over.
        for _ in 0..<5 {
            let launch = makeGuard(fs, limit: 2)
            #expect(try launch.beginLaunch() == .normal)
            try launch.markBackgrounded()
        }
    }

    @Test func backgroundingKeepsTheCountAndDoesNotCallTheLaunchStable() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        for _ in 0..<2 { _ = try makeGuard(fs).beginLaunch() }   // two real crashes
        let launch = makeGuard(fs)
        _ = try launch.beginLaunch()                              // third: counts the second crash
        try launch.markBackgrounded()
        // One more crash after this still reaches the limit: backgrounding proved nothing.
        let next = makeGuard(fs)
        #expect(try next.beginLaunch() == .normal)
        #expect(try makeGuard(fs).beginLaunch() == .safeMode(uncleanLaunches: 3))
    }

    @Test func backgroundingASettledLaunchChangesNothing() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        let launch = makeGuard(fs, limit: 1)
        _ = try launch.beginLaunch()
        try launch.markStable()
        try launch.markBackgrounded()
        #expect(try makeGuard(fs, limit: 1).beginLaunch() == .normal)
    }

    @Test(.failureMode("design/15", "the device restarts during a launch")) func aRestartDuringALaunchIsNotACrash() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        _ = try makeGuard(fs, limit: 1, boot: "boot-1").beginLaunch()
        // The battery died: the next launch is in another boot session.
        #expect(try makeGuard(fs, limit: 1, boot: "boot-2").beginLaunch() == .normal)
        // The same session finding it unfinished is a crash.
        #expect(try makeGuard(fs, limit: 1, boot: "boot-2").beginLaunch() == .safeMode(uncleanLaunches: 1))
    }

    @Test(.failureMode("design/15", "a different build launches after an unfinished one")) func aNewBuildStartsTheCountOver() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        for _ in 0..<3 { _ = try makeGuard(fs, build: "41").beginLaunch() }
        #expect(try makeGuard(fs, build: "41").beginLaunch() == .safeMode(uncleanLaunches: 3))
        // The update that fixes it gets a normal launch.
        #expect(try makeGuard(fs, build: "42").beginLaunch() == .normal)
    }

    @Test func aStateFileFromTheFirstFormatStillCounts() throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        let writer = AtomicFile(fileSystem: fs, options: .init(keepPrevious: true, checksFreeSpace: false))
        try writer.write(Array("stoic.launch v1 in-progress=1 unclean=2".utf8), to: "/app/launch-guard")
        #expect(try makeGuard(fs, build: "42").beginLaunch() == .safeMode(uncleanLaunches: 3))
    }

    @Test func interruptionsAreReported() async throws {
        let fs = SimulatedFileSystem()
        try fs.createDirectory("/app")
        let events = RecordingInstrumentation()
        try await withAmbient({ $0.instrumentation = events }) {
            let launch = makeGuard(fs)
            _ = try launch.beginLaunch()
            try launch.markBackgrounded()
        }
        let reasons = events.events(named: "launch.interrupted").map { event in event.fields.first { $0.key == "reason" }.map { "\($0.value)" } }
        #expect(reasons == ["backgrounded"])
    }
}
