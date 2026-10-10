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

    /// What the device is going through; backoff stretches with it.
    public var conditions: any SystemConditionsSource

    /// Groups the tasks Stoic starts in the ``TaskLedger``, so a test can ask
    /// whether everything *it* started has finished. Set by test tooling.
    public var ledgerTag: UInt64?

    /// Where the tasks Stoic starts itself prefer to run — state work,
    /// timers, supervised children, superseding work, abandoned-work
    /// watchers. `nil`, the default, is the global concurrent executor.
    ///
    /// Structured child tasks already inherit their parent's preference;
    /// unstructured tasks do not, so Stoic passes this on when it starts
    /// one. A deterministic simulation sets it to run every Stoic task on its
    /// seeded executor. Actors with their own executors, the main actor
    /// among them, run where they always do.
    public var taskExecutor: (any TaskExecutor)?

    /// What Stoic's fault points do (``FaultPolicy``). `nil`, the default,
    /// means nothing: set only by simulations.
    public var faultPolicy: (any FaultPolicy)?

    public init(
        clock: AnyClock = .continuous,
        livenessClock: AnyClock = .suspending,
        random: RandomSource = .system,
        instrumentation: any Instrumentation = OSLogInstrumentation(),
        budgets: RetryBudgets = .shared,
        conditions: any SystemConditionsSource = FixedConditions()
    ) {
        self.clock = clock
        self.livenessClock = livenessClock
        self.random = random
        self.instrumentation = instrumentation
        self.budgets = budgets
        self.conditions = conditions
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
    package static func record(_ event: Event) {
        let instrumentation = current.instrumentation
        guard instrumentation.isEnabled(event.level) else { return }
        instrumentation.record(event)
    }

    /// Records the event `make` builds, building it only if its level is
    /// enabled: for debug events on hot paths.
    package static func record(level: Event.Level, _ make: () -> Event) {
        let instrumentation = current.instrumentation
        guard instrumentation.isEnabled(level) else { return }
        instrumentation.record(make())
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
