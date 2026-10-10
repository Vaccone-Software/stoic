@testable import Stoic
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

    @Test func worstCaseCountsEveryAttemptAndEveryDelay() {
        let schedule = Schedule.fixed(.milliseconds(650)).attempts(2)
        #expect(schedule.worstCase(attemptTimeout: .milliseconds(2500)) == .milliseconds(5650))
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
            let bases: [Schedule] = [.fixed(base), .linear(base), .exponential(base: base), .fibonacci(base), .decorrelated(base: base, cap: cap)]
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
