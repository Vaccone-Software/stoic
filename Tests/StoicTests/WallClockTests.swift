@testable import Stoic
import StoicTesting
import Testing

@Suite("Wall clock")
struct WallClockTests {
    @Test func aTestsWallClockStartsAtAFixedMomentAndMovesWithItsClock() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            #expect(Moment.now == TestClock.wallClockStart)
            #expect(Moment.now.rfc3339 == "2026-01-01T00:00:00Z")
            await clock.advance(by: .seconds(90))
            #expect(Moment.now == TestClock.wallClockStart + .seconds(90))
        }
        #expect(clock.wallClockNow == TestClock.wallClockStart + .seconds(90))
    }

    @Test func aTestCanStartItsWallClockOnAnotherDay() async throws {
        let start = try #require(Moment(rfc3339: "2027-03-14T13:00:00Z"))
        let clock = TestClock(wallClockStart: start)
        let read = await withTestAmbient(clock: clock) { Moment.now }
        #expect(read == start)
    }

    /// A person sets the clock back an hour: moments jump, and nothing
    /// measured on the monotonic clock does.
    @Test(.failureMode("design/26", "a test jumps the wall clock alone"))
    func jumpingTheWallClockMovesMomentsAndNotDeadlinesOrSleeps() async throws {
        let clock = TestClock()
        let woke = SendableBox(false)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await Ambient.sleep(for: .seconds(60))
                woke.mutate { $0 = true }
            }
        }
        await clock.waitForSleepers(count: 1)
        let deadline = await withTestAmbient(clock: clock) { Deadline.after(.seconds(30)) }
        let before = clock.wallClockNow

        clock.jumpWallClock(by: .seconds(-3600))
        let readAfterJump = await withTestAmbient(clock: clock) { Moment.now }
        #expect(readAfterJump == before - .seconds(3600))
        #expect(clock.now == .init(offset: .zero), "the monotonic clock did not move")
        #expect(clock.pendingDeadlines == [.init(offset: .seconds(60))], "the sleep did not move")
        #expect(clock.sleeperCount == 1 && !woke.value, "nothing woke")
        #expect(deadline.instant.offset == .seconds(30) && !deadline.hasPassed)

        clock.jumpWallClock(to: TestClock.wallClockStart + .seconds(86_400))
        #expect(clock.wallClockNow == TestClock.wallClockStart + .seconds(86_400))
        #expect(clock.sleeperCount == 1, "a jump forward a whole day wakes nothing either")

        await clock.advance(by: .seconds(60))
        try await task.value
        #expect(woke.value)
        #expect(clock.wallClockNow == TestClock.wallClockStart + .seconds(86_460), "time passing moves the jumped clock on")
    }

    /// The clock is set back an hour while a thirty-second timeout waits: it
    /// still fires thirty seconds in, because it is on the continuous clock.
    @Test(.failureMode("design/26", "the wall clock jumps backwards during a timeout"))
    func aWallClockJumpBackwardsDuringATimeoutDoesNotMoveIt() async throws {
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(30)) { try await Ambient.sleep(for: .seconds(3600)) }
            }
        }
        // Both timers (the timeout and the work's sleep) are armed before
        // anything moves, so their instants are fixed.
        await clock.waitForSleepers(count: 2)
        clock.jumpWallClock(by: .seconds(-3600))
        await clock.advance(by: .seconds(29))
        #expect(clock.sleeperCount == 2, "an hour back on the wall clock gave the timeout no more and no less time")
        await clock.advance(by: .seconds(1))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.wallClockNow == TestClock.wallClockStart - .seconds(3600) + .seconds(30))
    }

    @Test func anImmediateClocksWallClockMovesWithItsSleeps() async throws {
        let clock = ImmediateClock()
        let (start, end) = try await withTestAmbient(clock: clock) {
            let start = Moment.now
            try await Ambient.sleep(for: .seconds(5))
            return (start, Moment.now)
        }
        #expect(start == TestClock.wallClockStart)
        #expect(end == TestClock.wallClockStart + .seconds(5))
    }

    @Test func aSimulationsWallClockIsItsClocks() async throws {
        let run = try await simulate(seed: 3) { sim in
            let start = Moment.now
            try await Ambient.sleep(for: .seconds(42))
            return (start, Moment.now, sim.clock.wallClockNow)
        }
        let (start, end, clocks) = run.value
        #expect(start == TestClock.wallClockStart)
        #expect(end == start + .seconds(42))
        #expect(end == clocks)
    }

    @Test(.stoic(seed: 1)) func theStoicTraitHoldsTheWallClockAtTheStart() {
        #expect(Moment.now == TestClock.wallClockStart)
    }
}
