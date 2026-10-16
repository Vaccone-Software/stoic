@testable import Stoic
import StoicTesting
import Testing

@Suite("Schedules")
struct ScheduleTests {
    @Test func basesProduceTheirDelays() {
        #expect(Schedule.fixed(.seconds(1)).maximalDelays(limit: 3) == [.seconds(1), .seconds(1), .seconds(1)])
        #expect(Schedule.linear(.seconds(1)).maximalDelays(limit: 3) == [.seconds(1), .seconds(2), .seconds(3)])
        #expect(Schedule.exponential(base: .seconds(1)).maximalDelays(limit: 4) == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
        #expect(Schedule.exponential(base: .seconds(1), factor: 3).maximalDelays(limit: 3) == [.seconds(1), .seconds(3), .seconds(9)])
        #expect(Schedule.fibonacci(.seconds(1)).maximalDelays(limit: 6) == [1, 1, 2, 3, 5, 8].map(Duration.seconds))
    }

    @Test func exponentialIsCappedAtFiveMinutesByDefault() {
        let delays = Schedule.exponential(base: .seconds(1)).maximalDelays(limit: 20)
        #expect(delays.max() == .seconds(300))
    }

    @Test func cappingReplacesTheDefaultCap() {
        let longer = Schedule.exponential(base: .seconds(1)).capped(at: .seconds(1000)).maximalDelays(limit: 20)
        #expect(longer.max() == .seconds(1000))
        let shorter = Schedule.exponential(base: .seconds(1)).capped(at: .seconds(5)).maximalDelays(limit: 20)
        #expect(shorter.max() == .seconds(5))
    }

    @Test func attemptsCountTheFirstAttempt() {
        let schedule = Schedule.fixed(.seconds(1)).attempts(3)
        #expect(schedule.maximumAttempts == 3)
        #expect(schedule.schedule.maximalDelays(limit: 100).count == 2)
        #expect(Schedule.fixed(.seconds(1)).attempts(1).maximumAttempts == 1)
    }

    @Test func explicitDelaysAreBoundedByTheirLength() {
        let schedule = Schedule.delays([.seconds(10), .seconds(60), .seconds(300)])
        #expect(schedule.maximumAttempts == 4)
        #expect(schedule.maximumTotalDelay == .seconds(370))
    }

    @Test func worstCaseCountsEveryAttemptAndEveryDelayAsAStrugglingDeviceStretchesIt() {
        // Two attempts of 2.5 s, and one 650 ms delay stretched eight times.
        let schedule = Schedule.fixed(.milliseconds(650)).attempts(2)
        #expect(schedule.maximumTotalDelay == .milliseconds(650))
        #expect(schedule.worstCase(attemptTimeout: .milliseconds(2500)) == .milliseconds(10_200))
        // A cap is the last word: never stretched past it.
        let capped = Schedule.fixed(.milliseconds(650)).capped(at: .seconds(1)).attempts(2)
        #expect(capped.worstCase(attemptTimeout: .milliseconds(2500)) == .milliseconds(6000))
        let defaultCap = Schedule.exponential(base: .seconds(100)).attempts(3)
        #expect(defaultCap.worstCase(attemptTimeout: .zero) == .seconds(600), "both delays held at the five-minute default cap")
    }

    @Test func theStretchWorstCaseAssumesIsTheMostTheDeviceApplies() {
        let worst = SystemConditions(memoryPressure: .critical, thermal: .critical, lowPowerMode: true)
        #expect(worst.backoffFactor == BoundedSchedule.maximumBackoffFactor)
    }

    @Test func elapsedStopsOnceTimeIsUp() {
        var stepper = Schedule.fixed(.seconds(1)).upTo(elapsed: .seconds(3)).makeStepper(random: RandomSource.seeded(1).generator())
        #expect(stepper.next(elapsed: .seconds(0)) == .seconds(1))
        #expect(stepper.next(elapsed: .seconds(2)) == .seconds(1))
        #expect(stepper.next(elapsed: .seconds(3)) == nil)
    }

    @Test func unionTakesTheShorterDelayWhileEitherContinues() {
        let union = Schedule.fixed(.seconds(5)).attempts(2).union(Schedule.fixed(.seconds(1)).attempts(4))
        #expect(union.schedule.maximalDelays(limit: 10) == [.seconds(1), .seconds(1), .seconds(1)])
    }

    @Test func intersectionTakesTheLongerDelayWhileBothContinue() {
        let intersection = Schedule.fixed(.seconds(1)).attempts(4).intersection(Schedule.fixed(.seconds(5)).attempts(2).schedule)
        #expect(intersection.schedule.maximalDelays(limit: 10) == [.seconds(5)])
    }

    @Test func andThenSwitchesSchedulesWhenTheFirstStops() {
        let schedule = Schedule.fixed(.seconds(1)).attempts(3).andThen(Schedule.fixed(.seconds(10)).attempts(2))
        #expect(schedule.schedule.maximalDelays(limit: 10) == [.seconds(1), .seconds(1), .seconds(10)])
    }

    @Test func fullJitterStaysWithinTheDelayAndIsReproducible() {
        let schedule = Schedule.fixed(.seconds(10)).jittered()
        func draw(seed: UInt64) -> [Duration] {
            var stepper = schedule.makeStepper(random: RandomSource.seeded(seed).generator(fileID: "T", line: 1))
            return (0..<200).compactMap { _ in stepper.next(elapsed: .zero) }
        }
        let first = draw(seed: 9)
        #expect(first == draw(seed: 9))
        #expect(first != draw(seed: 10))
        #expect(first.allSatisfy { $0 >= .zero && $0 <= .seconds(10) })
        #expect(Set(first).count > 150, "jitter should actually vary")
    }

    @Test func equalJitterKeepsAFloor() {
        var stepper = Schedule.fixed(.seconds(10)).jittered(.equal).makeStepper(random: RandomSource.seeded(3).generator())
        for _ in 0..<200 {
            let delay = stepper.next(elapsed: .zero)
            #expect(delay.map { $0 >= .seconds(5) && $0 <= .seconds(10) } == true)
        }
    }

    @Test func decorrelatedJitterStaysBetweenBaseAndCap() {
        var stepper = Schedule.decorrelated(base: .milliseconds(100), cap: .seconds(2)).makeStepper(random: RandomSource.seeded(5).generator())
        for _ in 0..<500 {
            let delay = stepper.next(elapsed: .zero)
            #expect(delay.map { $0 >= .milliseconds(100) && $0 <= .seconds(2) } == true)
        }
    }

    @Test func scheduleArithmeticNeverTraps() {
        let huge = Schedule.exponential(base: .seconds(1_000_000), factor: 1000).capped(at: Duration(attoseconds: .max))
        let delays = huge.maximalDelays(limit: 300)
        #expect(delays.count == 300)
        #expect(delays.allSatisfy { $0 >= .zero })
        #expect(Schedule.fibonacci(.seconds(1)).capped(at: Duration(attoseconds: .max)).maximalDelays(limit: 500).count == 500)
    }

    @Test func randomSchedulesRespectTheirCapsAndNeverGoNegative() {
        // Property: for many generated schedules, every jittered delay lies
        // within [0, cap] and the bounded ones stop where they say they will.
        var generator = RandomSource.seeded(2026).generator()
        for _ in 0..<300 {
            let base = Duration.milliseconds(Int.random(in: 0...5_000, using: &generator))
            let cap = Duration.milliseconds(Int.random(in: 1...60_000, using: &generator))
            let attempts = Int.random(in: 1...12, using: &generator)
            let jitter = [Jitter.full, .equal, .none].randomElement(using: &generator)!
            let bases: [Schedule] = [.fixed(base), .linear(base), .exponential(base: base), .fibonacci(base), .decorrelated(base: max(base, .milliseconds(1)), cap: cap)]
            let schedule = bases.randomElement(using: &generator)!.capped(at: cap).jittered(jitter).attempts(attempts)
            var stepper = schedule.makeStepper(random: RandomSource.seeded(UInt64(attempts)).generator())
            var count = 0
            while let delay = stepper.next(elapsed: .zero) {
                #expect(delay >= .zero && delay <= cap, "\(schedule) produced \(delay)")
                count += 1
            }
            #expect(count == attempts - 1, "\(schedule)")
            #expect(schedule.maximumAttempts == attempts)
        }
    }

    @Test func schedulesDescribeThemselves() {
        let description = Schedule.exponential(base: .seconds(1)).jittered().attempts(4).description
        #expect(description.contains("exponential"))
        #expect(description.contains("jittered(full)"))
        #expect(description.contains("attempts(4)"))
    }
}

@Suite("Schedules: review fixes")
struct ScheduleReviewTests {
    @Test func cappingTwiceKeepsTheSmallerCap() {
        #expect(Schedule.fixed(.seconds(5)).capped(at: .seconds(1)).capped(at: .seconds(10)).maximalDelays(limit: 2) == [.seconds(1), .seconds(1)])
    }

    @Test func aCapAfterJitterCanStillRaiseTheDefault() {
        let delays = Schedule.exponential(base: .seconds(1)).jittered().capped(at: .seconds(3600)).maximalDelays(limit: 20)
        #expect(delays.max() == .seconds(3600))
    }

    @Test func exponentialIsJitteredByDefaultAndCanBeMadeExact() {
        var jittered = Schedule.exponential(base: .seconds(1)).makeStepper(random: RandomSource.seeded(1).generator())
        var exact = Schedule.exponential(base: .seconds(1)).unjittered().makeStepper(random: RandomSource.seeded(1).generator())
        let a = (0..<5).compactMap { _ in jittered.next(elapsed: .zero) }
        let b = (0..<5).compactMap { _ in exact.next(elapsed: .zero) }
        #expect(b == [1, 2, 4, 8, 16].map(Duration.seconds))
        #expect(zip(a, b).allSatisfy { $0 <= $1 })
        #expect(a != b)
    }

    @Test func degenerateBasesAndFactorsNeverTrap() {
        #expect(Schedule.exponential(base: .zero).attempts(2000).maximumAttempts == 2000)
        #expect(Schedule.exponential(base: .zero).attempts(2000).maximumTotalDelay == .zero)
        #expect(Schedule.exponential(base: .seconds(1), factor: .infinity).attempts(5).maximumTotalDelay == .seconds(1 + 300 * 3))
        #expect(Schedule.exponential(base: .seconds(1), factor: .nan).unjittered().attempts(3).maximumTotalDelay == .seconds(2))
        #expect(Schedule.exponential(base: .seconds(1), factor: 0.5).unjittered().attempts(3).maximumTotalDelay == .seconds(2))
    }

    @Test func anElapsedLimitNeverSchedulesADelayPastIt() {
        // The limit is when waiting must be over: a minute's delay does not
        // fit a ten-second limit, even when it would begin inside it.
        #expect(Schedule.fixed(.seconds(60)).upTo(elapsed: .seconds(10)).maximalDelays(limit: 5) == [])
        var stepper = Schedule.fixed(.seconds(4)).upTo(elapsed: .seconds(10)).makeStepper(random: RandomSource.seeded(1).generator())
        #expect(stepper.next(elapsed: .seconds(1)) == .seconds(4))   // ends at 5 s
        #expect(stepper.next(elapsed: .seconds(6)) == .seconds(4))   // ends at exactly 10 s
        #expect(stepper.next(elapsed: .seconds(7)) == nil)           // would end at 11 s
    }

    @Test func decorrelatedRaisesACapBelowItsBase() {
        let delays = Schedule.decorrelated(base: .seconds(2), cap: .seconds(1)).maximalDelays(limit: 3)
        #expect(delays == [.seconds(2), .seconds(2), .seconds(2)])
    }

    /// A trap cannot be caught in-process, so the check runs in a child
    /// process that must die on it.
    @Test(.failureMode("design/02", "`decorrelated` is given a base that is not positive"))
    func decorrelatedRefusesABaseThatCouldNeverBackOff() async {
        await #expect(processExitsWith: .failure) {
            _ = Schedule.decorrelated(base: .zero, cap: .seconds(10))
        }
        await #expect(processExitsWith: .failure) {
            _ = Schedule.decorrelated(base: .seconds(-1), cap: .seconds(-2))
        }
    }

    @Test func boundsAreStructuralAndCheap() {
        // Previously O(n) in time and memory, and wrong under jitter + elapsed.
        let huge = Schedule.immediate.attempts(Int.max)
        #expect(huge.maximumAttempts == Int.max)
        #expect(huge.maximumTotalDelay == .zero)
        let jitteredElapsed = Schedule.fixed(.seconds(1)).jittered().upTo(elapsed: .seconds(10)).attempts(1000)
        #expect(jitteredElapsed.maximumAttempts == 1000, "an elapsed limit cannot lower a true upper bound")
        #expect(Schedule.fixed(.seconds(1)).attempts(3).andThen(Schedule.fixed(.seconds(2)).attempts(4)).maximumAttempts == 6)
        #expect(Schedule.fixed(.seconds(1)).attempts(3).union(Schedule.fixed(.seconds(2)).attempts(4)).maximumAttempts == 4)
        #expect(Schedule.fixed(.seconds(1)).attempts(3).intersection(Schedule.fixed(.seconds(2))).maximumAttempts == 3)
    }
}
