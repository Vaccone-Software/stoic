@testable import Stoic
import StoicTesting
import Testing

@Suite("Foundation")
struct FoundationTests {
    // MARK: AnyClock

    @Test func erasingWellKnownClocksSharesThem() {
        #expect(AnyClock(ContinuousClock()).isSameClock(as: .continuous))
        #expect(AnyClock(SuspendingClock()).isSameClock(as: .suspending))
        #expect(!AnyClock.continuous.isSameClock(as: .suspending))
    }

    @Test func erasingAnAnyClockIsIdentity() {
        let clock = TestClock().erased
        #expect(AnyClock(clock).isSameClock(as: clock))
    }

    @Test func separateErasuresOfACustomClockAreDifferentClocks() {
        let test = TestClock()
        #expect(!AnyClock(test).isSameClock(as: AnyClock(test)))
    }

    @Test func anyClockTracksTheUnderlyingClock() async {
        let test = TestClock()
        let clock = test.erased
        let start = clock.now
        await test.advance(by: .seconds(5))
        #expect(start.duration(to: clock.now) == .seconds(5))
    }

    @Test func anyClockSleepsOnTheUnderlyingClock() async throws {
        let test = TestClock()
        let clock = test.erased
        async let slept: Void = clock.sleep(until: clock.now.advanced(by: .seconds(3)), tolerance: nil)
        await test.waitForSleepers(count: 1)
        await test.advance(by: .seconds(3))
        try await slept
        #expect(test.sleeperCount == 0)
    }

    /// The century clamp has a lower half: an instant further in the past
    /// than the underlying clock can represent returns at once instead of
    /// trapping in the clock's conversion to seconds. Run in process, not as
    /// an exit test (whose child aborts under Address Sanitizer whatever it
    /// does): a regression traps, which fails the run loudly enough.
    @Test(.timeLimit(.minutes(1))) func sleepingUntilAnInstantFarInThePastReturnsAtOnce() async throws {
        try await AnyClock.continuous.sleep(until: AnyClock.Instant(offset: .minimum))
        try await AnyClock.suspending.sleep(until: AnyClock.Instant(offset: .minimum))
    }

    // MARK: Saturating arithmetic

    @Test func durationArithmeticSaturates() {
        #expect(Duration.maximum.saturatingAdding(.seconds(1)) == .maximum)
        #expect(Duration.minimum.saturatingSubtracting(.seconds(1)) == .minimum)
        #expect(Duration.seconds(1).saturatingMultiplied(by: 1e300) == .maximum)
        #expect(Duration.seconds(1).saturatingMultiplied(by: -1e300) == .minimum)
        #expect(Duration.seconds(1).saturatingMultiplied(by: .nan) == .zero)
        #expect(Duration.seconds(2).saturatingMultiplied(by: 1.5) == .seconds(3))
        #expect(AnyClock.Instant(offset: .maximum).advanced(by: .seconds(1)).offset == .maximum)
    }

    // MARK: RandomSource

    @Test func aSeedReproducesTheSameStream() {
        var a = RandomSource.seeded(42).generator(discriminator: 1, fileID: "A/a.swift", line: 10)
        var b = RandomSource.seeded(42).generator(discriminator: 1, fileID: "A/a.swift", line: 10)
        let first = (0..<16).map { _ in a.next() }
        let second = (0..<16).map { _ in b.next() }
        #expect(first == second)
    }

    @Test func streamsDifferBySeedSiteAndDiscriminator() {
        func head(_ source: RandomSource, _ discriminator: UInt64, _ file: String, _ line: UInt) -> UInt64 {
            var generator = source.generator(discriminator: discriminator, fileID: file, line: line)
            return generator.next()
        }
        let base = head(.seeded(1), 0, "A/a.swift", 1)
        #expect(base != head(.seeded(2), 0, "A/a.swift", 1))
        #expect(base != head(.seeded(1), 1, "A/a.swift", 1))
        #expect(base != head(.seeded(1), 0, "A/b.swift", 1))
        #expect(base != head(.seeded(1), 0, "A/a.swift", 2))
    }

    @Test func aSeededStreamIsKnownAcrossReleases() {
        // Pinned: a seed printed by a failing test today must reproduce the
        // same run after any future release. Changing this value is a
        // breaking change to every recorded seed.
        var generator = RandomSource.seeded(0).generator(discriminator: 0, fileID: "Stoic/Pinned.swift", line: 1)
        #expect(generator.next() == 10_777_668_820_459_565_016)
        #expect(generator.next() == 2_987_859_354_929_134_145)
    }

    // MARK: Ambient

    @Test func withAmbientScopesTheChangeToTheOperation() async {
        let clock = TestClock().erased
        await withAmbient({ $0.clock = clock }) {
            #expect(Ambient.current.clock.isSameClock(as: clock))
        }
        #expect(Ambient.current.clock.isSameClock(as: .continuous))
    }

    @Test func childTasksInheritTheAmbientContext() async {
        let clock = TestClock().erased
        await withAmbient({ $0.clock = clock }) {
            async let inherited = Ambient.current.clock.isSameClock(as: clock)
            #expect(await inherited)
        }
    }

    enum Typed: Error, Equatable { case boom }

    @Test func withAmbientPassesTypedErrorsThrough() async {
        await #expect(throws: Typed.boom) {
            try await withAmbient({ _ in }) { () throws(Typed) in throw Typed.boom }
        }
    }

    @Test @MainActor func withAmbientRunsOnTheCallersActor() async {
        final class NonSendable { var value = 0 }
        let state = NonSendable()
        await withAmbient({ _ in }) {
            MainActor.assertIsolated()
            state.value += 1
        }
        #expect(state.value == 1)
    }

    // MARK: Instrumentation

    @Test func eventFieldsDefaultToSafePrivacy() {
        let event = Event("test.event", fields: [
            .init("attempt", .int(2)),
            .init("path", .string("/Users/someone")),
            .init("error", .error(Typed.boom)),
        ])
        #expect(event.fields.map(\.privacy) == [.public, .private, .private])
        if case .int(2) = event["attempt"] {} else { Issue.record("missing attempt field") }
    }

    @Test func recordingInstrumentationKeepsEventsInOrder() async {
        let events = RecordingInstrumentation()
        await withAmbient({ $0.instrumentation = events }) {
            Ambient.record(Event("a"))
            Ambient.record(Event("b"))
        }
        #expect(events.names == ["a", "b"])
    }

    // MARK: TestClock

    @Test func testClockWakesSleepersInDeadlineOrder() async throws {
        let clock = TestClock()
        let order = OrderLog()
        try await withThrowingTaskGroup { group in
            for (name, delay) in [("late", 3), ("early", 1), ("middle", 2)] {
                group.addTask {
                    try await clock.sleep(until: clock.now.advanced(by: .seconds(delay)), tolerance: nil)
                    order.append(name)
                }
            }
            await clock.waitForSleepers(count: 3)
            for _ in 0..<3 {
                await clock.advanceToNextDeadline()
                _ = try await group.next()
            }
        }
        #expect(order.values == ["early", "middle", "late"])
    }

    @Test func testClockSleepIsCancellable() async {
        let clock = TestClock()
        let task = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(60)), tolerance: nil) }
        await clock.waitForSleepers(count: 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test func immediateClockRecordsEverySleep() async throws {
        let clock = ImmediateClock()
        try await clock.sleep(until: clock.now.advanced(by: .seconds(2)), tolerance: nil)
        try await clock.sleep(until: clock.now.advanced(by: .milliseconds(500)), tolerance: nil)
        #expect(clock.sleeps == [.seconds(2), .milliseconds(500)])
        #expect(clock.now.offset == .milliseconds(2500))
    }
}

/// A thread-safe append-only log for tests.
final class OrderLog: Sendable {
    private let storage = SendableBox<[String]>([])
    func append(_ value: String) { storage.mutate { $0.append(value) } }
    var values: [String] { storage.value }
}

@Suite("Arithmetic edges")
struct ArithmeticEdgeTests {
    @Test func multiplicationHandlesNaNProductsAndIntegralFactorsExactly() {
        #expect(Duration.zero.saturatingMultiplied(by: .infinity) == .zero)
        #expect(Duration.seconds(31_536_000).saturatingMultiplied(by: 1) == .seconds(31_536_000))
        #expect(Duration.seconds(3).saturatingMultiplied(by: 4) == .seconds(12))
        #expect(Duration.seconds(-3).saturatingMultiplied(by: 1e30) == .minimum)
        #expect(Duration.maximum.saturatingMultiplied(by: 2) == .maximum)
        #expect(Duration.maximum.saturatingMultiplied(by: -2) == .minimum)
    }

    @Test func enormousTimeoutsWaitInsteadOfTrapping() async throws {
        // Previously "Overflow in +" inside the underlying clock.
        let value = try await withTimeout(Duration(attoseconds: .max)) { () throws(CancellationError) -> Int in 7 }
        #expect(value == 7)
        let other = try await withTimeout(.seconds(Int64.max)) { () throws(CancellationError) -> Int in 8 }
        #expect(other == 8)
    }

    struct Transient: Error {}

    @Test func enormousScheduleDelaysAreClampedToTheHorizon() async {
        let task = Task {
            try await retry(Schedule.fixed(Duration(attoseconds: .max)).attempts(2), budget: .unlimited) { _ throws(Transient) -> Int in
                throw Transient()
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = try? await task.value
    }
}

@Suite("Test clocks: review fixes")
struct TestClockReviewTests {
    @Test func theTestAmbientUsesTheClocksOwnErasure() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            #expect(Ambient.current.clock.isSameClock(as: clock.erased))
        }
        #expect(clock.erased.isSameClock(as: clock.erased))
    }

    @Test func waitingForSleepersEndsWhenCancelled() async {
        let clock = TestClock()
        await withKnownIssue("a cancelled wait is reported, not satisfied") {
            let waiter = Task { await clock.waitForSleepers(count: 1) }
            try? await Task.sleep(for: .milliseconds(5))
            waiter.cancel()
            await waiter.value   // previously hung forever
        }
    }
}
