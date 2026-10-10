@testable import Stoic
import StoicTesting
import Testing

@Suite("Recur")
struct RecurTests {
    enum Failure: Error, Equatable { case broken }

    @Test func runsAtOnceThenOnTheSchedule() async {
        let clock = ImmediateClock()
        let runs = SendableBox(0)
        await withTestAmbient(clock: clock) {
            await recur(Schedule.fixed(.seconds(60)).attempts(4)) { _ in
                runs.mutate { $0 += 1 }
                return .continue
            }
        }
        #expect(runs.value == 4)
        #expect(clock.sleeps == [.seconds(60), .seconds(60), .seconds(60)])
    }

    @Test func theOperationCanStopOrAskForASoonerRun() async {
        let clock = ImmediateClock()
        await withTestAmbient(clock: clock) {
            await recur(Schedule.fixed(.seconds(60))) { attempt in
                switch attempt.number {
                case 1: .continueAfter(.seconds(5))
                case 2: .continue
                default: .stop
                }
            }
        }
        #expect(clock.sleeps == [.seconds(5), .seconds(60)])
    }

    @Test func aFailureEndsTheLoopAndIsRethrown() async {
        await #expect(throws: Failure.broken) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await recur(Schedule.fixed(.seconds(1))) { attempt throws(Failure) in
                    if attempt.number == 3 { throw .broken }
                    return .continue
                }
            }
        }
    }

    @Test func cancellationEndsAnUnboundedLoopQuietly() async {
        let clock = TestClock()
        let runs = SendableBox(0)
        let task = Task {
            await withTestAmbient(clock: clock) {
                await recur(Schedule.fixed(.seconds(30))) { _ in
                    runs.mutate { $0 += 1 }
                    return .continue
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(30))
        await clock.waitForSleepers(count: 1)
        task.cancel()
        await task.value
        #expect(runs.value == 2)
    }
}
