@testable import Stoic
import StoicTesting
import Testing

@Suite("Inactivity", .timeLimit(.minutes(1)))
struct InactivityTests {
    /// Lets work that is ready to run run.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test(.stoic(seed: 1), .failureMode("design/34", "nothing pokes it for the stretch"))
    func aWatcherReturnsOnceTheStretchPasses() async throws {
        let clock = TestClock()
        let inactivity = Inactivity(after: .seconds(10), label: "session", clock: clock.erased)
        let done = SendableBox(false)
        let watcher = Task {
            try await inactivity.untilQuiet()
            done.mutate { $0 = true }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(9))
        await settle()
        #expect(!done.value)
        #expect(!inactivity.isQuiet)
        await clock.advance(by: .seconds(1))
        try await watcher.value
        #expect(done.value)
        #expect(inactivity.quietFor == .seconds(10))
    }

    @Test(.stoic(seed: 2), .failureMode("design/34", "it is poked while a watcher waits"))
    func aPokeMovesTheEndOfTheWait() async throws {
        let clock = TestClock()
        let inactivity = Inactivity(after: .seconds(10), label: "session", clock: clock.erased)
        let done = SendableBox(false)
        let watcher = Task {
            try await inactivity.untilQuiet()
            done.mutate { $0 = true }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(6))
        let mark = clock.totalSleeps
        inactivity.poke()
        await clock.advance(by: .seconds(4))   // 10: the first wait ends, sees the poke, sleeps again
        await clock.waitForSleepers(newerThan: mark)
        #expect(!done.value)
        await clock.advance(by: .seconds(5))   // 15: still a second short of 6 + 10
        await settle()
        #expect(!done.value)
        await clock.advance(by: .seconds(1))
        try await watcher.value
        #expect(done.value)
    }

    @Test(.stoic(seed: 3), .failureMode("design/34", "the machine sleeps"))
    func sleepIsNotSilence() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            // Made with no clock: the ambient liveness clock, which a
            // sleeping machine does not advance; the wall clock jumps.
            let inactivity = Inactivity(after: .seconds(600), label: "session")
            clock.jumpWallClock(by: .seconds(3600))
            #expect(!inactivity.isQuiet)
            #expect(inactivity.quietFor == .zero)
        }
    }

    @Test(.stoic(seed: 4), .failureMode("design/34", "a quiet spell goes on"))
    func eachSpellIsReportedOnce() async throws {
        let clock = TestClock()
        let inactivity = Inactivity(after: .seconds(10), label: "session", clock: clock.erased)
        let spells = SendableBox<[Duration]>([])
        let watcher = Task {
            for await quiet in inactivity.quietSpells() { spells.mutate { $0.append(quiet) } }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(10))
        #expect(await eventually { spells.value.count == 1 })
        await clock.advance(by: .seconds(60))   // the same spell, longer: nothing new
        await settle()
        #expect(spells.value == [.seconds(10)])
        let mark = clock.totalSleeps
        inactivity.poke()
        await clock.waitForSleepers(newerThan: mark)
        await clock.advance(by: .seconds(10))
        #expect(await eventually { spells.value.count == 2 })
        watcher.cancel()
        await watcher.value
        #expect(StoicTest.events.events(named: "inactivity.quiet").count == 2)
    }

    /// A poke that lands as the watcher turns from one spell to wait for
    /// the next is heard. 0.9.0 read whether the spell had been reported and
    /// registered for the next poke in two steps, and a poke between them was
    /// lost: the watcher waited for another poke, and the quiet that followed
    /// was never reported (75 of 2,000 rounds on an M-series Mac). Raced on
    /// real threads; a correct round always reaches the clock, a lost one
    /// never does, so the first lost round ends the test.
    @Test(.stoic(seed: 7), .failureMode("design/34", "a poke lands as a watcher turns to wait for one"))
    func aPokeAsTheWatcherTurnsToTheNextSpellIsHeard() async throws {
        for round in 0..<500 {
            let clock = TestClock()
            let inactivity = Inactivity(after: .seconds(10), label: "session", clock: clock.erased)
            let spells = inactivity.quietSpells()
            let first = Task { var spell = spells.makeAsyncIterator(); return await spell.next() }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(10))
            #expect(await first.value == .seconds(10))
            // The watcher turns to the next spell as the work pokes, on two threads.
            let second = Task.detached { var spell = spells.makeAsyncIterator(); return await spell.next() }
            await Task.detached { inactivity.poke() }.value
            let heard = await eventually { clock.sleeperCount == 1 }
            #expect(heard, "round \(round): the poke was lost, and the watcher waits for another")
            guard heard else {
                second.cancel()
                _ = await second.value
                return
            }
            await clock.advance(by: .seconds(10))
            #expect(await second.value == .seconds(10))
        }
    }

    @Test(.stoic(seed: 5), .failureMode("design/34", "the watcher is cancelled"))
    func aCancelledWatcherEnds() async {
        let clock = TestClock()
        let inactivity = Inactivity(after: .seconds(10), label: "session", clock: clock.erased)
        let waiting = Task { try await inactivity.untilQuiet() }
        let spells = Task { () -> Int in
            var count = 0
            for await _ in inactivity.quietSpells() { count += 1 }
            return count
        }
        let poked = Task { try await inactivity.nextPoke() }
        await clock.waitForSleepers(count: 2)
        waiting.cancel()
        spells.cancel()
        poked.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await #expect(throws: CancellationError.self) { try await poked.value }
        #expect(await spells.value == 0)
    }

    /// A poke made before the waiter has registered is not its next poke,
    /// so the test pokes until the waiter hears one: a fixed number of
    /// yields was not enough on a three-core CI runner, the one poke came
    /// first, and the test waited for another forever (0.9.0's release run
    /// hung on it). Bounded, and a waiter that hears nothing is not awaited,
    /// so it can fail but never hang.
    @Test(.stoic(seed: 6))
    func aPokeWakesThoseWaitingForOne() async throws {
        let clock = TestClock()
        let inactivity = Inactivity(after: .seconds(10), label: "session", clock: clock.erased)
        let heard = SendableBox(false)
        let waiting = Task {
            try await inactivity.nextPoke()
            heard.mutate { $0 = true }
        }
        let wasHeard = await eventually { inactivity.poke(); return heard.value }
        #expect(wasHeard, "no poke reached the waiter")
        // Awaited only once it has heard: a waiter that never does is left
        // cancelled, so a lost wake-up fails the test instead of hanging it.
        waiting.cancel()
        if wasHeard { try await waiting.value }
    }
}
