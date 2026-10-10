import Stoic
import StoicStore
import StoicTesting
import Testing

@Suite("LaunchGuard")
struct LaunchGuardTests {
    func makeGuard(_ fs: SimulatedFileSystem, limit: Int = 3) -> LaunchGuard {
        LaunchGuard(path: "/app/launch-guard", uncleanLimit: limit, file: AtomicFile(fileSystem: fs, options: .init(keepPrevious: true, checksFreeSpace: false)))
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
}
