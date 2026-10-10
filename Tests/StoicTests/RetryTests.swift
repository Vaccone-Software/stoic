@testable import Stoic
import StoicTesting
import Testing

@Suite("Retry")
struct RetryTests {
    enum Failure: Error, Equatable, Retryable {
        case transient(Int)
        case permanent
        case slowDown(Duration)

        var retryDecision: RetryDecision {
            switch self {
            case .transient: .retry
            case .permanent: .stop
            case .slowDown(let after): .retryAfter(after)
            }
        }
    }

    struct Bug: Defect, Equatable {}

    /// Fails with `.transient(n)` until attempt `succeedOn`.
    func flaky(succeedOn: Int) -> @Sendable (Attempt) throws(Failure) -> Int {
        { attempt throws(Failure) in
            guard attempt.number >= succeedOn else { throw .transient(attempt.number) }
            return attempt.number
        }
    }

    @Test func succeedsAfterTransientFailuresWithTheScheduledDelays() async throws {
        let clock = ImmediateClock()
        let events = RecordingInstrumentation()
        let operation = flaky(succeedOn: 3)
        let value = try await withTestAmbient(clock: clock, events: events) {
            try await retry(.exponential(base: .seconds(1)).unjittered().attempts(5), budget: .unlimited) { attempt throws(Failure) in
                try operation(attempt)
            }
        }
        #expect(value == 3)
        #expect(clock.sleeps == [.seconds(1), .seconds(2)])
        #expect(events.names == ["retry.attempt_failed", "retry.attempt_failed", "retry.succeeded"])
    }

    @Test func exhaustingTheScheduleRethrowsTheLastError() async {
        let clock = ImmediateClock()
        let events = RecordingInstrumentation()
        let operation = flaky(succeedOn: 100)
        await #expect(throws: Failure.transient(3)) {
            try await withTestAmbient(clock: clock, events: events) {
                try await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { attempt throws(Failure) in
                    try operation(attempt)
                }
            }
        }
        #expect(clock.sleeps.count == 2)
        #expect(events.names.last == "retry.exhausted")
    }

    @Test func aPermanentFailureStopsImmediately() async {
        let clock = ImmediateClock()
        let attempts = SendableBox(0)
        await #expect(throws: Failure.permanent) {
            try await withTestAmbient(clock: clock) {
                try await retry(.fixed(.seconds(1)).attempts(5), budget: .unlimited) { _ throws(Failure) in
                    attempts.mutate { $0 += 1 }
                    throw .permanent
                }
            }
        }
        #expect(attempts.value == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func aDefectStopsEvenWhenTheClassifierWouldRetry() async {
        let events = RecordingInstrumentation()
        await #expect(throws: Bug()) {
            try await withTestAmbient(clock: ImmediateClock(), events: events) {
                try await retry(.fixed(.seconds(1)).attempts(5), budget: .unlimited, classify: RetryClassifier<Bug> { _ in .retry }) { _ throws(Bug) in
                    throw Bug()
                }
            }
        }
        #expect(events.names == ["retry.defect"])
    }

    @Test func decodingErrorsAreNotRetried() async {
        let attempts = SendableBox(0)
        await #expect(throws: DecodingError.self) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.fixed(.seconds(1)).attempts(5), budget: .unlimited) { _ in
                    attempts.mutate { $0 += 1 }
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
                }
            }
        }
        #expect(attempts.value == 1)
    }

    @Test func transientOnlyStopsOnUnknownErrors() async {
        struct Unknown: Error {}
        let attempts = SendableBox(0)
        await #expect(throws: Unknown.self) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.fixed(.seconds(1)).attempts(5), budget: .unlimited, classify: .transientOnly) { _ throws(Unknown) in
                    attempts.mutate { $0 += 1 }
                    throw Unknown()
                }
            }
        }
        #expect(attempts.value == 1)
    }

    @Test func retryAfterOverridesTheScheduleDelay() async throws {
        let clock = ImmediateClock()
        let value = try await withTestAmbient(clock: clock) {
            try await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { attempt throws(Failure) -> Int in
                if attempt.number == 1 { throw .slowDown(.seconds(42)) }
                return attempt.number
            }
        }
        #expect(value == 2)
        #expect(clock.sleeps == [.seconds(42)])
    }

    @Test func retryAfterIsCapped() async throws {
        let clock = ImmediateClock()
        _ = try await withTestAmbient(clock: clock) {
            try await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { attempt throws(Failure) -> Int in
                if attempt.number == 1 { throw .slowDown(.seconds(86_400)) }
                return attempt.number
            }
        }
        #expect(clock.sleeps == [.seconds(300)])
    }

    @Test func anEmptyBudgetStopsRetrying() async {
        let clock = ImmediateClock()
        let events = RecordingInstrumentation()
        let budget = RetryBudget(ratio: 0, reservePerSecond: 0, reserveCapacity: 1)
        let operation = flaky(succeedOn: 100)
        await #expect(throws: Failure.transient(2)) {
            try await withTestAmbient(clock: clock, events: events) {
                try await retry(.fixed(.seconds(1)).attempts(10), budget: budget) { attempt throws(Failure) in
                    try operation(attempt)
                }
            }
        }
        #expect(clock.sleeps.count == 1)
        #expect(events.names.last == "retry.budget_exhausted")
    }

    @Test func aBudgetSharedAcrossCallsBoundsTheirRetries() async {
        // Ten callers each failing permanently-transiently: with a reserve of
        // three and no earned tokens, only three retries happen in total.
        let budget = RetryBudget(ratio: 0, reservePerSecond: 0, reserveCapacity: 3)
        let attempts = SendableBox(0)
        await withTestAmbient(clock: ImmediateClock()) {
            for _ in 0..<10 {
                _ = try? await retry(.fixed(.seconds(1)).attempts(5), budget: budget) { _ throws(Failure) -> Int in
                    attempts.mutate { $0 += 1 }
                    throw .transient(0)
                }
            }
        }
        #expect(attempts.value == 10 + 3)
    }

    @Test func aRetryThatCannotFinishBeforeTheDeadlineIsSkipped() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let operation = flaky(succeedOn: 100)
        await #expect(throws: Failure.transient(1)) {
            try await withTestAmbient(clock: clock, events: events) {
                try await withTimeout(.seconds(3)) { () async throws(Failure) -> Int in
                    try await retry(.fixed(.seconds(5)).attempts(5), budget: .unlimited) { attempt throws(Failure) in
                        try operation(attempt)
                    }
                }
            }
        }
        #expect(events.names.contains("retry.deadline_skip"))
    }

    @Test func aNestedRetryMakesOneAttempt() async {
        let events = RecordingInstrumentation()
        let inner = SendableBox(0)
        await #expect(throws: Failure.transient(0)) {
            try await withTestAmbient(clock: ImmediateClock(), events: events) {
                try await retry(.fixed(.seconds(1)).attempts(2), budget: .unlimited) { _ throws(Failure) -> Int in
                    try await retry(.fixed(.seconds(1)).attempts(5), budget: .unlimited) { _ throws(Failure) -> Int in
                        inner.mutate { $0 += 1 }
                        throw .transient(0)
                    }
                }
            }
        }
        #expect(inner.value == 2, "one inner attempt per outer attempt")
        #expect(events.events(named: "retry.nested").count == 2)
    }

    @Test func aNestedRetryMayOptIn() async {
        let inner = SendableBox(0)
        await #expect(throws: Failure.transient(0)) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.fixed(.seconds(1)).attempts(1), budget: .unlimited) { _ throws(Failure) -> Int in
                    try await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited, nesting: .allow) { _ throws(Failure) -> Int in
                        inner.mutate { $0 += 1 }
                        throw .transient(0)
                    }
                }
            }
        }
        #expect(inner.value == 3)
    }

    @Test func cancellingTheCallerDuringBackoffRethrowsTheLastError() async {
        let clock = TestClock()
        let attempts = SendableBox(0)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await retry(.fixed(.seconds(10)).attempts(5), budget: .unlimited) { _ throws(Failure) -> Int in
                    attempts.mutate { $0 += 1 }
                    throw .transient(attempts.value)
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        task.cancel()
        await #expect(throws: Failure.transient(1)) { try await task.value }
        #expect(attempts.value == 1)
    }

    @Test func aTimedOutAttemptIsRetried() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let task = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await retry(.fixed(.seconds(1)).attempts(3), attemptTimeout: .seconds(2), budget: .unlimited) { attempt in
                    if attempt.number == 1 {
                        try await Ambient.sleep(for: .seconds(60))   // hangs until its timeout cancels it
                    }
                    return attempt.number
                }
            }
        }
        await clock.waitForSleepers(count: 2)   // the attempt and its timer
        await clock.advance(by: .seconds(2))    // the attempt times out
        await clock.waitForSleepers(count: 1)   // the backoff
        await clock.advance(by: .seconds(1))
        #expect(try await task.value == 2)
        let failed = events.events(named: "retry.attempt_failed")
        #expect(failed.count == 1)
        if case .bool(true) = failed.first?["timed_out"] {} else { Issue.record("expected timed_out=true") }
    }

    @Test @MainActor func theInlineFormRunsOnTheCallersActor() async throws {
        final class Counter { var value = 0 }
        let counter = Counter()
        let value = try await withTestAmbient(clock: ImmediateClock()) {
            try await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(Failure) -> Int in
                MainActor.assertIsolated()
                counter.value += 1
                if counter.value < 3 { throw .transient(counter.value) }
                return counter.value
            }
        }
        #expect(value == 3)
    }

    @Test func aSeedReproducesTheJitteredDelays() async throws {
        func delays(seed: UInt64) async -> [Duration] {
            let clock = ImmediateClock()
            _ = try? await withTestAmbient(clock: clock, seed: seed) {
                try await retry(.exponential(base: .seconds(1)).jittered().attempts(6), budget: .unlimited) { _ throws(Failure) -> Int in
                    throw .transient(0)
                }
            }
            return clock.sleeps
        }
        let first = await delays(seed: 77)
        #expect(first.count == 5)
        #expect(await delays(seed: 77) == first)
        #expect(await delays(seed: 78) != first)
    }
}

@Suite("Retry: review fixes")
struct RetryReviewTests {
    struct Bug: Defect {}
    struct Transient: Error {}

    @Test func aCancellationErrorIsNotRetriedWhenTheCallerIsNotCancelled() async {
        let attempts = SendableBox(0)
        await #expect(throws: CancellationError.self) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.fixed(.seconds(1)).attempts(3)) { _ in
                    attempts.mutate { $0 += 1 }
                    throw CancellationError()
                }
            }
        }
        #expect(attempts.value == 1)
    }

    @Test func aDefectInsideAPolicyErrorStops() async {
        let events = RecordingInstrumentation()
        let attempts = SendableBox(0)
        await #expect(throws: PolicyError<Bug>.self) {
            try await withTestAmbient(clock: ImmediateClock(), events: events) {
                try await retry(.fixed(.seconds(1)).attempts(4)) { _ throws(PolicyError<Bug>) in
                    attempts.mutate { $0 += 1 }
                    throw .failed(Bug())
                }
            }
        }
        #expect(attempts.value == 1)
        #expect(events.names == ["retry.defect"])
    }

    @Test func aTimedOutAttemptIsRetriedEvenUnderACustomClassifier() async throws {
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await retry(.fixed(.seconds(1)).attempts(3), attemptTimeout: .seconds(2),
                                classify: RetryClassifier<any Error> { $0 is CancellationError ? .stop : .retry }) { attempt in
                    if attempt.number == 1 { try await Ambient.sleep(for: .seconds(60)) }
                    return attempt.number
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(2))
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        #expect(try await task.value == 2)
    }

    @Test func theDefaultBudgetIsFreshInEveryTestAmbient() async {
        func run() async -> Int {
            let attempts = SendableBox(0)
            _ = try? await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.fixed(.milliseconds(10)).attempts(5)) { _ throws(Transient) -> Int in
                    attempts.mutate { $0 += 1 }
                    throw Transient()
                }
            }
            return attempts.value
        }
        var counts: [Int] = []
        for _ in 0..<8 { counts.append(await run()) }
        #expect(counts == Array(repeating: 5, count: 8), "previously [5, 5, 3, 1, 2, 1, 1, 1]")
    }

    @Test func tenDepositsOfATenthMakeExactlyOneToken() async {
        let budget = RetryBudget(ratio: 0.1, reservePerSecond: 0, reserveCapacity: 0)
        let attempts = SendableBox(0)
        await withTestAmbient(clock: ImmediateClock()) {
            for _ in 0..<10 {
                _ = try? await retry(.fixed(.seconds(1)).attempts(1), budget: budget) { _ throws(Transient) -> Int in throw Transient() }
            }
            _ = try? await retry(.fixed(.seconds(1)).attempts(5), budget: budget) { _ throws(Transient) -> Int in
                attempts.mutate { $0 += 1 }
                throw Transient()
            }
        }
        // The eleventh call deposits 0.1 more, so 1.1 tokens: exactly one retry.
        #expect(attempts.value == 2)
    }

    @Test func aTaskLeftRunningByAnAttemptIsNotNested() async throws {
        let attempts = SendableBox(0)
        let gate = AsyncGate()
        let leftover = SendableBox<Task<Void, Never>?>(nil)
        try await withTestAmbient(clock: ImmediateClock()) {
            _ = try await retry(.fixed(.seconds(1)).attempts(1)) { _ throws(Transient) -> Int in
                // This task inherits the attempt's task-locals and outlives it.
                leftover.mutate {
                    $0 = Task {
                        await gate.wait()
                        _ = try? await retry(.fixed(.seconds(1)).attempts(3)) { _ throws(Transient) -> Int in
                            attempts.mutate { $0 += 1 }
                            throw Transient()
                        }
                    }
                }
                return 1
            }
        }
        gate.open()
        await leftover.value?.value
        #expect(attempts.value == 3, "the attempt had ended, so the later retry is not nested")
    }
}
