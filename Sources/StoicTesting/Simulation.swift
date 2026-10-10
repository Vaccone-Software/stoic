public import Stoic
internal import Darwin
internal import Dispatch
internal import Synchronization

/// Runs `body` as a deterministic simulation: every interleaving decided by
/// `seed`, time virtual and advanced only when everything is asleep.
///
///     @Test func syncSurvivesEveryInterleaving() async throws {
///         try await simulate(seeds: 0..<500) { sim in
///             let engine = SyncEngine(store: FakeStore())
///             try await engine.syncAll()
///             try #require(engine.pending.isEmpty)   // #require: a failing #expect does not stop the seed
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
    faults: SimulatedFaults = .standard,
    _ body: @escaping @Sendable (SimulationContext) async throws -> R
) async throws(SimulationFailure) -> Simulated<R> {
    let seed = seed ?? StoicTest.current?.seed ?? 0
    let simulation = Simulation(seed: seed, limits: limits, faults: faults, body: body)
    // Started here, not on the driver's thread, so the body inherits the
    // caller's task-locals (the running test, its traits). Its first job
    // waits in the executor's queue until the driver runs it.
    let task = simulation.start()
    let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Simulation<R>.Outcome, Never>) in
            // The driver blocks a thread for the whole run, by design: it is
            // the one thread the simulation runs on. Never a cooperative one.
            DispatchQueue(label: "stoic.simulation.\(seed)").async {
                continuation.resume(returning: simulation.drive(task))
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
///   says whether the second run failed the same way, at the same step,
///   along the same path. A body that keeps state between runs (captured
///   from outside it) can make that `false` on its own.
public func simulate(
    seeds: some Sequence<UInt64>,
    limits: SimulationLimits = .standard,
    faults: SimulatedFaults = .standard,
    _ body: @escaping @Sendable (SimulationContext) async throws -> Void
) async throws(SimulationFailure) {
    for seed in seeds {
        do {
            _ = try await simulate(seed: seed, limits: limits, faults: faults, body)
        } catch {
            var failure = error
            // A cancelled exploration is over; there is nothing to reproduce.
            if case .cancelled = failure.kind { throw failure }
            do {
                _ = try await simulate(seed: seed, limits: limits, faults: faults, body)
                failure.reproduced = false
            } catch let again {
                failure.reproduced = again.kind.name == failure.kind.name
                    && again.steps == failure.steps && again.fingerprint == failure.fingerprint
            }
            throw failure
        }
    }
}

/// How often Stoic's fault points perturb a simulated run (FoundationDB's
/// `BUGGIFY`).
///
/// Each fault point compiled into a primitive — a semaphore waiter about to
/// queue, a channel send, superseded work about to deliver, a finalizer
/// starting, a retry attempt, a service starting — is switched on for a run
/// with probability `siteProbability`, decided by the seed the first time
/// the run reaches it. A switched-on site fires with probability
/// `fireProbability` each time it is reached: half the time it yields a few
/// scheduling turns, half the time it sleeps up to `maxDelay` of virtual
/// time. Rare timing becomes routine, and a failing seed still replays.
public struct SimulatedFaults: Sendable, Hashable {
    public var siteProbability: Double
    public var fireProbability: Double
    public var maxDelay: Duration

    public init(siteProbability: Double = 0.25, fireProbability: Double = 0.25, maxDelay: Duration = .seconds(1)) {
        self.siteProbability = siteProbability
        self.fireProbability = fireProbability
        self.maxDelay = maxDelay
    }

    /// A quarter of the sites, a quarter of the time, up to a second.
    public static let standard = SimulatedFaults()

    /// No perturbation: only the scheduler's choices.
    public static let none = SimulatedFaults(siteProbability: 0, fireProbability: 0, maxDelay: .zero)
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
    /// How long a run that nothing outside has ever touched waits before it
    /// is called stalled. When no job has arrived from another thread, and
    /// no outside work is outstanding, nothing is likely to — a deadlock
    /// inside the simulation needs no two seconds of waiting. The little
    /// that remains covers a first hop to the main actor that has not
    /// arrived yet.
    public var quietStall: Duration

    public init(
        virtualTime: Duration = .seconds(24 * 3600),
        steps: Int = 5_000_000,
        stall: Duration = .seconds(2),
        quietStall: Duration = .milliseconds(50)
    ) {
        self.virtualTime = virtualTime
        self.steps = steps
        self.stall = stall
        self.quietStall = quietStall
    }

    /// A simulated day, five million steps, two seconds stalled (50
    /// milliseconds when nothing outside the simulation ever took part).
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
    /// Of those, the ones that were still running after the simulation
    /// cancelled them and gave them time to finish: waiting on something
    /// that ignores cancellation, or on a continuation nothing will resume.
    public let stuck: [TaskLedger.Entry]
    /// How many times each fault point fired, by site.
    public let faultsFired: [String: Int]
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
    /// The path the run took up to the failure (see ``Simulated/fingerprint``).
    public let fingerprint: UInt64
    /// Whether running the seed again failed the same way at the same step,
    /// when ``simulate(seeds:limits:_:)`` checked; `nil` when not checked.
    public internal(set) var reproduced: Bool?

    public var description: String {
        var text = "simulation with seed \(seed) \(kind.name) after \(steps) steps, \(elapsed) of virtual time"
        switch kind {
        case .threw(let error): text += ": \(error)"
        case .stalled(let tasks):
            text += ": nothing could run and nothing was asleep — a deadlock, or a wait on something the simulation does not drive (the main actor, Dispatch, real I/O)"
            if !tasks.isEmpty { text += "; Stoic tasks still running: " + tasks.map(\.description).joined(separator: ", ") }
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
    private let faults: SeededFaults
    private let body: @Sendable (SimulationContext) async throws -> R
    private let executor: SimulationExecutor
    private let clock = TestClock()
    private let events = RecordingInstrumentation()
    private let result = Mutex<Result<R, any Error>?>(nil)
    private let tag = LedgerTags.next()
    private let cancelRequested = Atomic<Bool>(false)

    init(seed: UInt64, limits: SimulationLimits, faults: SimulatedFaults, body: @escaping @Sendable (SimulationContext) async throws -> R) {
        self.seed = seed
        self.limits = limits
        self.faults = SeededFaults(seed: seed, settings: faults)
        self.body = body
        self.executor = SimulationExecutor(seed: seed)
    }

    func requestCancellation() {
        cancelRequested.store(true, ordering: .relaxed)
        executor.wake()
    }

    /// Runs the simulation to its end on the calling thread.
    /// Starts the body on the simulation's executor. Call from the caller's
    /// context, then ``drive(_:)``.
    func start() -> Task<Void, Never> {
        let faults = faults
        let context = SimulationContext(seed: seed, clock: clock, events: events)
        let body = body
        let erased = clock.erased
        let executor = executor
        let seed = seed
        let tag = tag
        return Task(executorPreference: executor) {
            let outcome: Result<R, any Error> = await withAmbient({ ambient in
                ambient.clock = erased
                ambient.livenessClock = erased
                ambient.random = .seeded(seed)
                ambient.instrumentation = context.events
                ambient.budgets = RetryBudgets()
                ambient.ledgerTag = tag
                ambient.taskExecutor = executor
                ambient.faultPolicy = faults
            }) {
                do {
                    return .success(try await body(context))
                } catch {
                    return .failure(error)
                }
            }
            self.result.withLock { $0 = outcome }
        }
    }

    /// Runs the simulation to its end on the calling thread.
    func drive(_ task: Task<Void, Never>) -> Outcome {
        executor.beginDriving()
        FaultPoint.install()
        defer { FaultPoint.uninstall() }
        let faults = faults
        let tag = tag
        let start = clock.now
        var steps = 0
        var fingerprint = Fingerprint()
        var failure: SimulationFailure.Kind?
        // After a failure the body is cancelled and given a bounded chance
        // to unwind, so its cleanup runs simulated too.
        var windDownSteps = 0
        var windDownEnds: TestClock.Instant?
        var outsideIsWedged = false

        func fail(_ kind: SimulationFailure.Kind) {
            guard failure == nil else { return }
            failure = kind
            task.cancel()
            windDownEnds = clock.now.advanced(by: .seconds(3600))
        }

        while true {
            if failure == nil, cancelRequested.load(ordering: .relaxed) { fail(.cancelled) }
            // The body's end is the run's end, even if something it left
            // behind could run forever: that is `leftover`, not a step limit.
            if self.result.withLock({ $0 != nil }) { break }
            if let (job, arrival, runnable) = executor.takeNext() {
                fingerprint.mix(UInt64(runnable))
                fingerprint.mix(arrival)
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
            if let windDownEnds, clock.now >= windDownEnds { break }
            // Time stands still while work handed outside is outstanding:
            // it would be done by now in real time.
            // Once a wait for it has timed out, it is wedged, not slow: stop
            // waiting for it before every timer.
            if !ExternalWork.isOutstanding(tag: tag) {
                outsideIsWedged = false
            } else if !outsideIsWedged {
                if executor.waitForArrival(within: limits.stall) { continue }
                outsideIsWedged = true
            }
            if let now = clock.fireNextDeadline() {
                fingerprint.mix(UInt64(truncatingIfNeeded: start.duration(to: now).attoseconds))
                if start.duration(to: now) > limits.virtualTime { fail(.virtualTimeLimit) }
                continue
            }
            // Nothing runnable, nothing asleep. If nothing from outside has
            // taken part in this run, nothing is likely to start now.
            let patience = executor.sawOutsideArrival || ExternalWork.isOutstanding(tag: tag) ? limits.stall : min(limits.quietStall, limits.stall)
            if executor.waitForArrival(within: patience) { continue }
            if failure != nil { break }
            fail(.stalled(TaskLedger.entries(tag: tag)))
        }

        let elapsed = start.duration(to: clock.now)
        // What the run left behind, before it is cleaned up.
        let leftover = TaskLedger.entries(tag: tag)
        let stuck = unwind(task)
        if let failure {
            return .failure(SimulationFailure(kind: failure, seed: seed, steps: steps, elapsed: elapsed, fingerprint: fingerprint.value))
        }
        switch self.result.withLock({ $0 }) {
        case .success(let value)?:
            return .success(Simulated(
                value: value, seed: seed, steps: steps, elapsed: elapsed,
                fingerprint: fingerprint.value, leftover: leftover, stuck: stuck,
                faultsFired: faults.fired
            ))
        case .failure(let error)?:
            return .failure(SimulationFailure(kind: .threw(error), seed: seed, steps: steps, elapsed: elapsed, fingerprint: fingerprint.value))
        case nil:
            return .failure(SimulationFailure(kind: .stalled(TaskLedger.entries(tag: tag)), seed: seed, steps: steps, elapsed: elapsed, fingerprint: fingerprint.value))
        }
    }
}

extension Simulation {
    /// Cancels what the run left behind that Stoic can reach — its ledger
    /// tasks, and everything asleep on its clock — and drives the executor
    /// until it is quiet, a bounded number of steps. Without this, a task
    /// parked on the clock keeps the clock, and itself, alive for the rest
    /// of the process, and a cancelled one never gets to run its cleanup.
    /// Not counted in the run's steps or fingerprint.
    ///
    /// - Returns: The ledger tasks that were still running afterwards.
    fileprivate func unwind(_ root: Task<Void, Never>) -> [TaskLedger.Entry] {
        var budget = 20_000
        for _ in 0..<8 {
            root.cancel()
            TaskLedger.cancelAll(tag: tag)
            clock.cancelAllSleepers()
            while budget > 0, let (job, _, _) = executor.takeNext() {
                executor.run(job)
                budget -= 1
            }
            // Cleanup may itself have gone to sleep or started more work.
            if budget == 0 || (clock.sleeperCount == 0 && TaskLedger.entries(tag: tag).isEmpty) { break }
        }
        return TaskLedger.entries(tag: tag)
    }
}

/// The fault policy of one run: which sites are on, and when they fire,
/// all from the seed.
final class SeededFaults: FaultPolicy {
    private struct State {
        var random: SplitMix
        var enabled: [String: Bool] = [:]
        var fired: [String: Int] = [:]
    }

    private let settings: SimulatedFaults
    private let state: Mutex<State>

    init(seed: UInt64, settings: SimulatedFaults) {
        self.settings = settings
        // Its own stream, so faults do not shift the scheduler's choices.
        state = Mutex(State(random: SplitMix(seed: seed ^ 0xB066_1F1E_D00D_F00D)))
    }

    var fired: [String: Int] {
        state.withLock { $0.fired }
    }

    func action(at site: String) -> FaultAction {
        let settings = settings
        return state.withLock { state in
            func chance(_ probability: Double) -> Bool {
                Double(state.random.next() >> 11) / Double(1 << 53) < probability
            }
            let on: Bool
            if let decided = state.enabled[site] {
                on = decided
            } else {
                on = chance(settings.siteProbability)
                state.enabled[site] = on
            }
            guard on, chance(settings.fireProbability) else { return .proceed }
            state.fired[site, default: 0] += 1
            if state.random.next() & 1 == 0 {
                return .yield(Int(1 + state.random.next() % 4))
            }
            let limit = max(1, settings.maxDelay.components.seconds * 1000 + settings.maxDelay.components.attoseconds / 1_000_000_000_000_000)
            return .delay(.milliseconds(1 + Int64(state.random.next() % UInt64(limit))))
        }
    }
}

/// A task executor that queues jobs and lets its driver run them one at a
/// time, choosing the next from a seed.
final class SimulationExecutor: TaskExecutor {
    private struct State {
        var jobs: [(job: UnownedJob, arrival: UInt64)] = []
        var arrivals: UInt64 = 0
        var random: SplitMix
        // The driver's thread, once it starts, and whether any job has been
        // enqueued from another one since.
        var driverThread: UInt64?
        var sawOutside = false
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
        let thread = currentThreadID()
        state.withLock { state in
            if let driver = state.driverThread, driver != thread { state.sawOutside = true }
            state.arrivals += 1
            state.jobs.append((job, state.arrivals))
        }
        arrival.signal()
    }

    /// Marks the calling thread as the driver. Jobs enqueued from any other
    /// thread after this are work from outside the simulation.
    func beginDriving() {
        let thread = currentThreadID()
        state.withLock { $0.driverThread = thread }
    }

    /// Whether a job has arrived from a thread other than the driver's.
    var sawOutsideArrival: Bool {
        state.withLock { $0.sawOutside }
    }

    /// Removes a job chosen by the seed among all runnable ones. Also returns
    /// its arrival number and how many were runnable, for the fingerprint:
    /// the arrival number tells two runs apart that chose the same index
    /// from queues in different orders.
    func takeNext() -> (UnownedJob, UInt64, Int)? {
        state.withLock { state in
            guard !state.jobs.isEmpty else { return nil }
            let count = state.jobs.count
            let index = Int(state.random.next() % UInt64(count))
            state.jobs.swapAt(index, count - 1)
            let (job, arrival) = state.jobs.removeLast()
            return (job, arrival, count)
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
        // Capped at a day: a larger wait would overflow the dispatch time.
        let nanoseconds = Int(min(max(seconds, 0), 86_400)) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        return arrival.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success
    }

    /// Wakes a driver waiting for arrivals, to notice a cancellation.
    func wake() {
        arrival.signal()
    }
}

/// An identifier of the calling thread, stable for its life.
func currentThreadID() -> UInt64 {
    var id: UInt64 = 0
    unsafe pthread_threadid_np(nil, &id)
    return id
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
