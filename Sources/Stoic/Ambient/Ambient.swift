/// The cross-cutting context every Stoic primitive reads: its clocks, its
/// randomness, and where its events go.
///
/// Threading these through every signature is noise, and forgetting one
/// breaks determinism, so they live in one task-local value. Child tasks
/// inherit it. A test replaces it once, at the top, and every retry,
/// deadline and supervisor beneath runs on the test's clock and seed.
///
/// Every primitive that takes a `clock:` or `random:` argument lets that
/// argument override the ambient value for one call.
public struct Ambient: Sendable {
    /// The clock for deadlines, timeouts and retry delays.
    ///
    /// Continuous by default: if the machine sleeps through a deadline, the
    /// deadline has passed.
    public var clock: AnyClock

    /// The clock for liveness: watchdogs and heartbeats.
    ///
    /// Suspending by default: a process that was asleep was not hung.
    public var livenessClock: AnyClock

    /// The source of jitter and every other random choice.
    public var random: RandomSource

    /// Where events go.
    public var instrumentation: any Instrumentation

    /// The shared retry budgets: per call site and named.
    public var budgets: RetryBudgets

    public init(
        clock: AnyClock = .continuous,
        livenessClock: AnyClock = .suspending,
        random: RandomSource = .system,
        instrumentation: any Instrumentation = OSLogInstrumentation(),
        budgets: RetryBudgets = .shared
    ) {
        self.clock = clock
        self.livenessClock = livenessClock
        self.random = random
        self.instrumentation = instrumentation
        self.budgets = budgets
    }

    @TaskLocal static var stored = Ambient()

    /// The context in force for the current task.
    public static var current: Ambient { stored }
}

/// Runs `operation` with a modified ambient context.
///
///     try await withAmbient({ $0.clock = AnyClock(testClock); $0.random = .seeded(7) }) {
///         try await syncEverything()
///     }
@discardableResult
public nonisolated(nonsending) func withAmbient<R, Failure: Error>(
    _ transform: (inout Ambient) -> Void,
    operation: nonisolated(nonsending) () async throws(Failure) -> R
) async throws(Failure) -> R {
    var ambient = Ambient.current
    transform(&ambient)
    return try await Ambient.$stored.withValueTyped(ambient, operation: operation)
}

extension TaskLocal {
    /// `withValue`, with the operation's error type preserved.
    nonisolated(nonsending) func withValueTyped<R, Failure: Error>(
        _ value: Value,
        operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(Failure) -> R {
        let outcome: Result<R, Failure> = await withValue(value) {
            do throws(Failure) {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }
}

extension Ambient {
    /// Records `event` with the current context's instrumentation.
    static func record(_ event: Event) {
        current.instrumentation.record(event)
    }
}

extension Ambient {
    /// Sleeps for `duration` on the ambient clock.
    ///
    /// Use this instead of `Task.sleep(for:)` in code that tests should be
    /// able to run on virtual time.
    public static func sleep(for duration: Duration, tolerance: Duration? = nil) async throws {
        let clock = current.clock
        try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: tolerance)
    }

    /// Sleeps until `instant` on the ambient clock.
    public static func sleep(until instant: AnyClock.Instant, tolerance: Duration? = nil) async throws {
        try await current.clock.sleep(until: instant, tolerance: tolerance)
    }
}
