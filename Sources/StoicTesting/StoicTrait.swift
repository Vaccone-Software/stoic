import Stoic
public import Testing

/// A Swift Testing trait that runs a test in an isolated, seeded Stoic
/// context: a fixed random seed, fresh retry budgets, and recorded events.
///
///     @Test(.stoic(seed: 42))
///     func syncRetriesThroughAnOutage() async throws {
///         try await syncEverything()
///         #expect(StoicTest.events.names.contains("retry.succeeded"))
///     }
///
/// The seed appears in the test's traits, so a failure names the run that
/// reproduces it. The clock is left as it is: give time-sensitive code a
/// ``TestClock`` explicitly, where the test can drive it.
public struct StoicTrait: TestTrait, SuiteTrait, TestScoping {
    public let seed: UInt64

    public var isRecursive: Bool { true }

    // `@concurrent`: Swift Testing declares this requirement without
    // NonisolatedNonsendingByDefault, which Stoic's targets enable.
    @concurrent
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let events = RecordingInstrumentation()
        try await StoicTest.$current.withValue(StoicTest(seed: seed, events: events)) {
            try await withAmbient({ ambient in
                ambient.random = .seeded(seed)
                ambient.instrumentation = events
                ambient.budgets = RetryBudgets()
            }) {
                try await function()
            }
        }
    }
}

extension Trait where Self == StoicTrait {
    /// Runs the test with a fixed seed, fresh budgets and recorded events.
    public static func stoic(seed: UInt64 = 0) -> StoicTrait {
        StoicTrait(seed: seed)
    }
}

/// What the ``StoicTrait`` installed for the running test.
public struct StoicTest: Sendable {
    public let seed: UInt64
    public let recorded: RecordingInstrumentation

    init(seed: UInt64, events: RecordingInstrumentation) {
        self.seed = seed
        self.recorded = events
    }

    @TaskLocal static var current: StoicTest?

    /// The events recorded so far in the running test. Empty outside a
    /// test with the trait.
    public static var events: RecordingInstrumentation {
        current?.recorded ?? RecordingInstrumentation()
    }
}
