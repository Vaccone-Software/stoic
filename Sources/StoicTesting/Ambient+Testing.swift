import Stoic

/// Runs `operation` with a fully controlled ambient context: the given clock
/// for both deadlines and liveness, a seeded random source, recorded
/// instrumentation, and fresh retry budgets, so no other test's retries can
/// change what this one sees.
///
///     let clock = TestClock()
///     let events = RecordingInstrumentation()
///     try await withTestAmbient(clock: clock, seed: 42, events: events) {
///         try await subjectUnderTest()
///     }
@discardableResult
public nonisolated(nonsending) func withTestAmbient<C: Clock<Duration>, R, Failure: Error>(
    clock: C,
    seed: UInt64 = 0,
    events: RecordingInstrumentation = RecordingInstrumentation(),
    operation: nonisolated(nonsending) () async throws(Failure) -> R
) async throws(Failure) -> R {
    let erased: AnyClock
    switch clock {
    case let test as TestClock: erased = test.erased
    case let immediate as ImmediateClock: erased = immediate.erased
    default: erased = AnyClock(clock)
    }
    return try await withAmbient({ ambient in
        ambient.clock = erased
        ambient.livenessClock = erased
        ambient.random = .seeded(seed)
        ambient.instrumentation = events
        ambient.budgets = RetryBudgets()
    }, operation: operation)
}
