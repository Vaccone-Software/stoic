public import Stoic
internal import Dispatch
internal import Synchronization

/// Runs `body` as a deterministic simulation: every interleaving decided by
/// `seed`, time virtual and advanced only when everything is asleep.
///
///     @Test func syncSurvivesEveryInterleaving() async throws {
///         try await simulate(seeds: 0..<500) { sim in
///             let engine = SyncEngine(store: FakeStore())
///             try await engine.syncAll()
///             #expect(engine.pending.isEmpty)
///         }
///     }
///
/// FoundationDB's discipline, for Swift. Concurrency bugs live in rare
/// orderings that a test run on real threads reaches once in a thousand runs
/// and never under a debugger. Here, one job runs at a time on one thread,
/// the next is chosen from the seed among everything runnable, and a failing
/// seed replays the exact same ordering, every time.
///
/// **What runs simulated.** The body and its structured children; every task
/// Stoic starts (through ``Ambient/taskExecutor``); and actors without their
/// own executor, which run wherever the task calling them prefers. The
/// ambient clock is a ``TestClock`` that the simulation advances to the next
/// deadline whenever no job is runnable — an hour of retries takes
/// milliseconds — and the ambient random source is seeded.
///
/// **What does not.** The main actor and other actors with their own
/// executors; `Task {}` started by your code (unstructured tasks do not
/// inherit an executor preference: start them with the ambient executor, or
/// use a Stoic primitive); Dispatch, real I/O and real clocks. The simulation
/// waits for work arriving from outside for up to `limits.stall` of real
/// time, but the moment it arrives is not seeded, so such a run may not
/// replay exactly; ``Simulated/fingerprint`` tells you whether two runs took
/// the same path.
///
/// - Parameters:
///   - seed: Decides every choice. The ``StoicTrait``'s seed, or zero, if `nil`.
///   - limits: When to give up: virtual time, steps, and real time stalled.
///   - body: The scenario. Runs on the simulation's executor.
/// - Returns: The body's value, with how the run went.
/// - Throws: ``SimulationFailure``, naming the seed that reproduces it.
public func simulate<R: Sendable>(
    seed: UInt64? = nil,
    limits: SimulationLimits = .standard,
    _ body: @escaping @Sendable (SimulationContext) async throws -> R
) async throws(SimulationFailure) -> Simulated<R> {
    let seed = seed ?? StoicTest.current?.seed ?? 0
    let simulation = Simulation(seed: seed, limits: limits, body: body)
    let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Simulation<R>.Outcome, Never>) in
            // The driver blocks a thread for the whole run, by design: it is
            // the one thread the simulation runs on. Never a cooperative one.
            DispatchQueue(label: "stoic.simulation.\(seed)").async {
                continuation.resume(returning: simulation.drive())
            }
        }
    } onCancel: {
        simulation.requestCancellation()
    }
    switch outcome {
    case .success(let simulated): return simulated
    case .failure(let failure): throw failure
    }
}

/// Runs `body` once per seed, stopping at the first failure — after running
/// that seed again to confirm it reproduces.
///
/// - Throws: The first ``SimulationFailure``; its ``SimulationFailure/reproduced``
///   says whether the second run failed the same way, at the same step.
public func simulate(
    seeds: some Sequence<UInt64>,
    limits: SimulationLimits = .standard,
    _ body: @escaping @Sendable (SimulationContext) async throws -> Void
) async throws(SimulationFailure) {
    for seed in seeds {
        do {
            _ = try await simulate(seed: seed, limits: limits, body)
        } catch {
            var failure = error
            do {
                _ = try await simulate(seed: seed, limits: limits, body)
                failure.reproduced = false
            } catch let again {
                failure.reproduced = again.steps == failure.steps && again.kind.name == failure.kind.name
            }
            throw failure
        }
    }
}

/// What a simulated body is given.
public struct SimulationContext: Sendable {
    /// The seed deciding this run.
    public let seed: UInt64
    /// The ambient clock, advanced by the simulation when everything sleeps.
    public let clock: TestClock
    /// Every event recorded in this run.
    public let events: RecordingInstrumentation
}

/// When a simulation gives up.
public struct SimulationLimits: Sendable {
    /// The most virtual time a run may take: a run still going past it is
    /// livelocked (retrying forever, a timer that re-arms itself).
    public var virtualTime: Duration
    /// The most jobs a run may execute.
    public var steps: Int
    /// The longest real time to wait for work arriving from outside the
    /// simulation (the main actor, Dispatch, real I/O) before calling the
    /// run stalled.
    public var stall: Duration

    public init(virtualTime: Duration = .seconds(24 * 3600), steps: Int = 5_000_000, stall: Duration = .seconds(2)) {
        self.virtualTime = virtualTime
        self.steps = steps
        self.stall = stall
    }

    /// A simulated day, five million steps, two seconds stalled.
    public static let standard = SimulationLimits()
}

/// A finished simulation.
public struct Simulated<Value: Sendable>: Sendable {
    /// What the body returned.
    public let value: Value
    public let seed: UInt64
    /// Jobs executed.
    public let steps: Int
    /// Virtual time the run took.
    public let elapsed: Duration
    /// A digest of every scheduling decision and clock move. Two runs with
    /// the same fingerprint took the same path.
    public let fingerprint: UInt64
    /// Stoic tasks still running when the body returned — usually a leak.
    public let leftover: [TaskLedger.Entry]
}

/// A simulation that went wrong, and the seed that makes it go wrong again.
public struct SimulationFailure: Error, CustomStringConvertible {
    public enum Kind: Sendable {
        /// The body threw.
        case threw(any Error)
        /// Nothing could run, nothing was asleep, and nothing arrived from
        /// outside: a deadlock, or a wait on something the simulation does
        /// not drive. Lists the Stoic tasks still running.
        case stalled([TaskLedger.Entry])
        /// Virtual time ran past the limit: a livelock.
        case virtualTimeLimit
        /// More jobs than the limit ran.
        case stepLimit
        /// The run was cancelled from outside.
        case cancelled

        var name: String {
            switch self {
            case .threw: "threw"
            case .stalled: "stalled"
            case .virtualTimeLimit: "virtual time limit"
            case .stepLimit: "step limit"
            case .cancelled: "cancelled"
            }
        }
    }

    public let kind: Kind
    public let seed: UInt64
    /// The step at which it went wrong.
    public let steps: Int
    /// Virtual time at that point.
    public let elapsed: Duration
    /// Whether running the seed again failed the same way at the same step,
    /// when ``simulate(seeds:limits:_:)`` checked; `nil` when not checked.
    public internal(set) var reproduced: Bool?

    public var description: String {
        var text = "simulation with seed \(seed) \(kind.name) after \(steps) steps, \(elapsed) of virtual time"
        switch kind {
        case .threw(let error): text += ": \(error)"
        case .stalled(let tasks):
            text += tasks.isEmpty
                ? " (no Stoic task running: the wait is on something outside the simulation)"
                : "; still running: " + tasks.map(\.description).joined(separator: ", ")
        default: break
        }
        switch reproduced {
        case true?: text += ". Reproduces: simulate(seed: \(seed))"
        case false?: text += ". Did NOT reproduce: something outside the simulation decided the outcome"
        case nil: text += ". Reproduce with simulate(seed: \(seed))"
        }
        return text
    }
}

// MARK: The engine

/// One run: the executor, the clock, and the loop that drives them.
final class Simulation<R: Sendable>: Sendable {
    enum Outcome: Sendable {
        case success(Simulated<R>)
        case failure(SimulationFailure)
    }

    private let seed: UInt64
    private let limits: SimulationLimits
    private let body: @Sendable (SimulationContext) async throws -> R
    private let executor: SimulationExecutor
    private let clock = TestClock()
    private let events = RecordingInstrumentation()
    private let result = Mutex<Result<R, any Error>?>(nil)
    private let cancelRequested = Atomic<Bool>(false)

    init(seed: UInt64, limits: SimulationLimits, body: @escaping @Sendable (SimulationContext) async throws -> R) {
        self.seed = seed
        self.limits = limits
        self.body = body
        self.executor = SimulationExecutor(seed: seed)
    }

    func requestCancellation() {
        cancelRequested.store(true, ordering: .relaxed)
        executor.wake()
    }

    /// Runs the simulation to its end on the calling thread.
    func drive() -> Outcome {
        let tag = LedgerTags.next()
        let context = SimulationContext(seed: seed, clock: clock, events: events)
        let body = body
        let erased = clock.erased
        let executor = executor
        let seed = seed
        let task = Task(executorPreference: executor) {
            let outcome: Result<R, any Error> = await withAmbient({ ambient in
                ambient.clock = erased
                ambient.livenessClock = erased
                ambient.random = .seeded(seed)
                ambient.instrumentation = context.events
                ambient.budgets = RetryBudgets()
                ambient.ledgerTag = tag
                ambient.taskExecutor = executor
            }) {
                do {
                    return .success(try await body(context))
                } catch {
                    return .failure(error)
                }
            }
            self.result.withLock { $0 = outcome }
        }

        let start = clock.now
        var steps = 0
        var fingerprint = Fingerprint()
        var failure: SimulationFailure.Kind?
        // After a failure the body is cancelled and given a bounded chance
        // to unwind, so its cleanup runs simulated too.
        var windDownSteps = 0
        var windDownEnds: TestClock.Instant?

        func fail(_ kind: SimulationFailure.Kind) {
            guard failure == nil else { return }
            failure = kind
            task.cancel()
            windDownEnds = clock.now.advanced(by: .seconds(3600))
        }

        while true {
            if failure == nil, cancelRequested.load(ordering: .relaxed) { fail(.cancelled) }
            if let (job, runnable, index) = executor.takeNext() {
                fingerprint.mix(UInt64(runnable))
                fingerprint.mix(UInt64(index))
                executor.run(job)
                steps += 1
                if failure != nil {
                    windDownSteps += 1
                    if windDownSteps > 100_000 { break }
                } else if steps >= limits.steps {
                    fail(.stepLimit)
                }
                continue
            }
            if self.result.withLock({ $0 != nil }) { break }
            if let windDownEnds, clock.now >= windDownEnds { break }
            if let now = clock.fireNextDeadline() {
                fingerprint.mix(UInt64(truncatingIfNeeded: start.duration(to: now).attoseconds))
                if start.duration(to: now) > limits.virtualTime { fail(.virtualTimeLimit) }
                continue
            }
            if executor.waitForArrival(within: limits.stall) { continue }
            if failure != nil { break }
            fail(.stalled(TaskLedger.entries(tag: tag)))
        }

        let elapsed = start.duration(to: clock.now)
        if let failure {
            return .failure(SimulationFailure(kind: failure, seed: seed, steps: steps, elapsed: elapsed))
        }
        switch self.result.withLock({ $0 }) {
        case .success(let value)?:
            return .success(Simulated(
                value: value, seed: seed, steps: steps, elapsed: elapsed,
                fingerprint: fingerprint.value, leftover: TaskLedger.entries(tag: tag)
            ))
        case .failure(let error)?:
            return .failure(SimulationFailure(kind: .threw(error), seed: seed, steps: steps, elapsed: elapsed))
        case nil:
            return .failure(SimulationFailure(kind: .stalled(TaskLedger.entries(tag: tag)), seed: seed, steps: steps, elapsed: elapsed))
        }
    }
}

/// A task executor that queues jobs and lets its driver run them one at a
/// time, choosing the next from a seed.
final class SimulationExecutor: TaskExecutor {
    private struct State {
        var jobs: [UnownedJob] = []
        var random: SplitMix
    }

    private let state: Mutex<State>
    // Signalled on every arrival, so a driver with nothing to run can wait
    // for work from outside the simulation without spinning.
    private let arrival = DispatchSemaphore(value: 0)

    init(seed: UInt64) {
        state = Mutex(State(random: SplitMix(seed: seed)))
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        state.withLock { $0.jobs.append(job) }
        arrival.signal()
    }

    /// Removes a job chosen by the seed among all runnable ones. Also returns
    /// how many were runnable and which was chosen, for the fingerprint.
    func takeNext() -> (UnownedJob, Int, Int)? {
        state.withLock { state in
            guard !state.jobs.isEmpty else { return nil }
            let count = state.jobs.count
            let index = Int(state.random.next() % UInt64(count))
            return (state.jobs.remove(at: index), count, index)
        }
    }

    func run(_ job: UnownedJob) {
        // unsafe: every job is taken from the queue exactly once and run
        // here, on this executor, which is what the runtime requires.
        unsafe job.runSynchronously(on: unsafe asUnownedTaskExecutor())
    }

    /// Waits up to `limit` of real time for a job to arrive.
    func waitForArrival(within limit: Duration) -> Bool {
        let (seconds, attoseconds) = limit.components
        let nanoseconds = Int(clamping: seconds.multipliedReportingOverflow(by: 1_000_000_000).partialValue + attoseconds / 1_000_000_000)
        return arrival.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success
    }

    /// Wakes a driver waiting for arrivals, to notice a cancellation.
    func wake() {
        arrival.signal()
    }
}

/// SplitMix64: small, fast, and identical on every platform.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// FNV-1a over 64-bit words.
struct Fingerprint {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func mix(_ word: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            value ^= (word >> UInt64(shift)) & 0xFF
            value = value &* 0x0000_0100_0000_01B3
        }
    }
}
