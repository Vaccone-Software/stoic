public import Stoic
internal import Synchronization

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
        ambient.ledgerTag = LedgerTags.next()
    }, operation: operation)
}

/// Waits until every task Stoic started in the current test context has
/// finished, and returns whatever is still running after `limit` — empty when
/// the test left nothing behind.
///
///     #expect(await stoicTasksStillRunning().isEmpty)
///
/// Uses real time, briefly: superseded and cancelled work needs a moment to
/// wind down. Only tasks started under ``withTestAmbient`` or the
/// ``StoicTrait`` are considered, so tests running in parallel do not see
/// each other's work.
public func stoicTasksStillRunning(within limit: Duration = .seconds(1)) async -> [TaskLedger.Entry] {
    guard let tag = Ambient.current.ledgerTag else { return [] }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while clock.now < deadline {
        if TaskLedger.entries(tag: tag).isEmpty { return [] }
        try? await clock.sleep(for: .milliseconds(1))
    }
    return TaskLedger.entries(tag: tag)
}

enum LedgerTags {
    private static let counter = Atomic<UInt64>(1)
    static func next() -> UInt64 { counter.wrappingAdd(1, ordering: .relaxed).newValue }
}
