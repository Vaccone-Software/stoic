internal import Darwin
internal import Dispatch
public import Stoic
internal import Synchronization
public import Testing

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
/// **How the next job is chosen.** By default the seed also chooses a
/// *schedule*: half the seeds pick uniformly among everything runnable, which
/// finds the bugs that need two tasks to interleave once; the others run
/// PCT (probabilistic concurrency testing) at depth two to four — tasks get
/// random priorities, the highest runs, and a few random moments demote the
/// task that just ran — which finds the bugs that need one task to run far
/// ahead of another. Independently, half the seeds let virtual time pass
/// while work is still runnable: a few times in a run the next timer fires
/// early, so a timeout that lands in the middle of a computation is found
/// too. ``Simulated/schedule`` says which a run used; `schedule:` forces one.
///
/// - Parameters:
///   - seed: Decides every choice. The ``StoicTrait``'s seed, or zero, if `nil`.
///   - limits: When to give up: virtual time, steps, and real time stalled.
///   - faults: How often fault points perturb the run.
///   - schedule: How the next job is chosen; the seed's choice by default.
///   - allowEscapes: Whether work that left the simulation is acceptable. By
///     default a run that took part with something the simulator does not
///     drive (an unstructured `Task {}`, `Task.detached`, Dispatch, a
///     `Timer`, a real-clock sleep, the main actor) or that ended with Stoic
///     tasks still running records a test issue: the run may not replay, and
///     the seed is not the whole story. Pass `true` when that is deliberate;
///     ``Simulated/report`` says what happened either way.
///   - sourceLocation: Where an escape is reported.
///   - body: The scenario. Runs on the simulation's executor.
/// - Returns: The body's value, with how the run went.
/// - Throws: ``SimulationFailure``, naming the seed that reproduces it.
public func simulate<R: Sendable>(
    seed: UInt64? = nil,
    limits: SimulationLimits = .standard,
    faults: SimulatedFaults = .standard,
    schedule: SimulationSchedule = .portfolio,
    allowEscapes: Bool = false,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable (SimulationContext) async throws -> R
) async throws(SimulationFailure) -> Simulated<R> {
    let simulated = try await run(seed: seed, limits: limits, faults: faults, schedule: schedule, body)
    if !allowEscapes, simulated.report.hasEscapes {
        Issue.record(Comment(rawValue: "simulation with seed \(simulated.seed): \(simulated.report)"), sourceLocation: sourceLocation)
    }
    return simulated
}

/// One run, without judging what it left behind.
private func run<R: Sendable>(
    seed: UInt64?,
    limits: SimulationLimits,
    faults: SimulatedFaults,
    schedule: SimulationSchedule,
    _ body: @escaping @Sendable (SimulationContext) async throws -> R
) async throws(SimulationFailure) -> Simulated<R> {
    let seed = seed ?? StoicTest.current?.seed ?? 0
    let simulation = Simulation(seed: seed, limits: limits, faults: faults, schedule: schedule, body: body)
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
///
/// Work that left the simulation (see `allowEscapes` on ``simulate(seed:limits:faults:schedule:allowEscapes:sourceLocation:_:)``)
/// is reported as one issue for the whole exploration: the first seed that
/// did it, and how many others did.
///
/// - Parameter allowEscapes: Pass `true` when escaping the simulation is
///   deliberate, to record no issue for it.
/// - Throws: The first ``SimulationFailure``; its ``SimulationFailure/reproduced``
///   says whether the second run failed the same way, at the same step,
///   along the same path. A body that keeps state between runs (captured
///   from outside it) can make that `false` on its own.
public func simulate(
    seeds: some Sequence<UInt64>,
    limits: SimulationLimits = .standard,
    faults: SimulatedFaults = .standard,
    schedule: SimulationSchedule = .portfolio,
    allowEscapes: Bool = false,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable (SimulationContext) async throws -> Void
) async throws(SimulationFailure) {
    var escaped: (seed: UInt64, report: SimulationReport)?
    var escapedCount = 0
    var ran = 0
    defer {
        if let escaped {
            let others = escapedCount > 1 ? " (and \(escapedCount - 1) of the other \(ran - 1) seeds run)" : ""
            Issue.record(Comment(rawValue: "simulation with seed \(escaped.seed)\(others): \(escaped.report)"), sourceLocation: sourceLocation)
        }
    }
    for seed in seeds {
        do {
            ran += 1
            let simulated = try await run(seed: seed, limits: limits, faults: faults, schedule: schedule, body)
            if !allowEscapes, simulated.report.hasEscapes {
                escapedCount += 1
                if escaped == nil { escaped = (seed, simulated.report) }
            }
        } catch {
            var failure = error
            // A cancelled exploration is over; there is nothing to reproduce.
            if case .cancelled = failure.kind { throw failure }
            do {
                _ = try await run(seed: seed, limits: limits, faults: faults, schedule: schedule, body)
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

/// How a simulation chooses which runnable job goes next, and whether time
/// may pass while work is still runnable.
public struct SimulationSchedule: Sendable, Hashable {
    public enum Strategy: Sendable, Hashable {
        /// The seed picks one of the others (about half the seeds uniform).
        case portfolio
        /// Uniformly among everything runnable.
        case uniform
        /// PCT: random task priorities, `depth - 1` random moments at which
        /// the running task is demoted. `horizon` is a guess at how many
        /// steps the run takes (the change points fall within it); the seed
        /// picks a magnitude when `nil`.
        case pct(depth: Int, horizon: Int?)
    }

    public var strategy: Strategy
    /// Whether, on some seeds, the next timer may fire while jobs are still
    /// runnable.
    public var earlyTimers: Bool

    public init(_ strategy: Strategy = .portfolio, earlyTimers: Bool = true) {
        self.strategy = strategy
        self.earlyTimers = earlyTimers
    }

    /// The seed picks the strategy and whether timers fire early.
    public static let portfolio = SimulationSchedule()
    /// Uniform choice only, timers only when everything is asleep.
    public static let uniform = SimulationSchedule(.uniform, earlyTimers: false)
    /// PCT at `depth` (at least 2), timers only when everything is asleep.
    public static func pct(depth: Int, horizon: Int? = nil) -> SimulationSchedule {
        SimulationSchedule(.pct(depth: depth, horizon: horizon), earlyTimers: false)
    }

    /// This schedule, with early timers on or off.
    public func earlyTimers(_ on: Bool) -> SimulationSchedule {
        var copy = self
        copy.earlyTimers = on
        return copy
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
    /// The schedule the run followed, such as `uniform` or
    /// `pct(depth 3, horizon 256), early timers 1 in 32`.
    public let schedule: String
    /// Stoic tasks still running when the body returned — usually a leak.
    public let leftover: [TaskLedger.Entry]
    /// Of those, the ones that were still running after the simulation
    /// cancelled them and gave them time to finish: waiting on something
    /// that ignores cancellation, or on a continuation nothing will resume.
    public let stuck: [TaskLedger.Entry]
    /// How many times each fault point fired, by site.
    public let faultsFired: [String: Int]
    /// What escaped the simulation: work from outside, tasks left running,
    /// and whether the run is deterministic as far as the simulator can
    /// tell. ``simulate(seed:limits:faults:schedule:allowEscapes:sourceLocation:_:)``
    /// records an issue for it unless told not to.
    public let report: SimulationReport

    /// How many jobs and sleeps came from outside the simulation. See
    /// ``SimulationReport/outsideArrivals``.
    public var outsideArrivals: Int { report.outsideArrivals }

    /// Whether the simulator saw nothing it could not replay. See
    /// ``SimulationReport/isDeterministic``.
    public var isDeterministic: Bool { report.isDeterministic }
}

/// What a finished simulation let escape, and whether it can be replayed.
///
/// A simulation is deterministic only while everything runs on its executor
/// and its clock. Work that does not — an unstructured `Task {}` (it does
/// not inherit the executor), `Task.detached`, Dispatch, a Foundation
/// `Timer`, `Task.sleep` on a real clock, an actor with its own executor,
/// the main actor — runs on real threads whose timing the seed does not
/// decide. Such work is waited for, so the run still finishes, but "the seed
/// that failed" may not fail again. This says how much of it there was.
public struct SimulationReport: Sendable, CustomStringConvertible {
    /// Jobs that were queued onto the simulation's executor from a thread
    /// other than its driver's: an unstructured task or a real timer waking
    /// a task that prefers the simulation.
    public let outsideJobs: Int
    /// Sleeps begun on the simulation's clock by a thread other than its
    /// driver's: a task the simulation does not drive, sleeping on the
    /// ambient ``TestClock``.
    public let outsideSleeps: Int
    /// Stoic tasks still running when the body returned: a leak. A fixed
    /// point: they were cancelled and driven to a stop afterwards.
    public let leftover: [TaskLedger.Entry]
    /// Of those, the ones still running after the simulation cancelled them.
    public let stuck: [TaskLedger.Entry]

    /// Everything that arrived from outside: jobs and clock sleeps.
    public var outsideArrivals: Int { outsideJobs + outsideSleeps }

    /// Whether the simulator saw nothing that makes the run unreplayable:
    /// no arrival from outside. It cannot see work that never touched the
    /// simulation at all (an unstructured `Task {}` the body never waits
    /// for), so `true` means "as far as it can tell".
    public var isDeterministic: Bool { outsideArrivals == 0 }

    /// Whether anything escaped: outside arrivals, or tasks left running.
    public var hasEscapes: Bool { !isDeterministic || !leftover.isEmpty }

    init(outsideJobs: Int, outsideSleeps: Int, leftover: [TaskLedger.Entry], stuck: [TaskLedger.Entry]) {
        self.outsideJobs = outsideJobs
        self.outsideSleeps = outsideSleeps
        self.leftover = leftover
        self.stuck = stuck
    }

    public var description: String {
        guard hasEscapes else { return "nothing escaped; the run is deterministic as far as the simulator can tell" }
        var parts: [String] = []
        if !isDeterministic {
            parts.append(
                """
                work escaped the simulation: \(outsideJobs) job(s) were queued from threads the simulator does not drive and \
                \(outsideSleeps) sleep(s) on its clock began there, so the run may not replay from its seed. \
                Likely causes: an unstructured Task {} or Task.detached in app code (neither inherits the simulation's executor), \
                DispatchQueue, a Foundation Timer, a sleep on a real clock (Task.sleep(for:), ContinuousClock), a hop to the main actor, \
                or abandoningAfter (its work runs on Dispatch). \
                Fix: start tasks the way Stoic does, with Task(executorPreference: Ambient.current.taskExecutor) { … } \
                (Task.stoic inside Stoic itself) or through a Stoic primitive, and sleep with Ambient.sleep(for:) \
                or a clock: parameter given sim.clock, never a real clock
                """)
        }
        if !leftover.isEmpty {
            parts.append(
                """
                \(leftover.count) Stoic task(s) were still running when the body returned\
                \(stuck.isEmpty ? "" : ", \(stuck.count) of them still running after being cancelled"): \
                \(leftover.map(\.description).joined(separator: ", ")). \
                A leak: await or cancel what the body starts (a Supervisor, a StateMachine, a TaskSlot, a scope) before it returns
                """)
        }
        return parts.joined(separator: "\n") + "\nIf this is deliberate, pass allowEscapes: true."
    }
}

/// A simulation that went wrong, and the seed that makes it go wrong again.
public struct SimulationFailure: Error, CustomStringConvertible {
    public enum Kind: Sendable, CustomStringConvertible {
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

        /// A short name for the kind: `threw`, `stalled`, `virtual time
        /// limit`, `step limit`, `cancelled`.
        public var name: String {
            switch self {
            case .threw: "threw"
            case .stalled: "stalled"
            case .virtualTimeLimit: "virtual time limit"
            case .stepLimit: "step limit"
            case .cancelled: "cancelled"
            }
        }

        public var description: String {
            switch self {
            case .threw(let error): "threw \(error)"
            case .stalled(let tasks): tasks.isEmpty ? "stalled" : "stalled with \(tasks.map(\.description).joined(separator: ", ")) running"
            default: name
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
    /// The schedule the run followed (see ``Simulated/schedule``).
    public let schedule: String
    /// Whether running the seed again failed the same way at the same step,
    /// when ``simulate(seeds:limits:_:)`` checked; `nil` when not checked.
    public internal(set) var reproduced: Bool?

    public var description: String {
        var text = "simulation with seed \(seed) \(kind.name) after \(steps) steps, \(elapsed) of virtual time [\(schedule)]"
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
    private let resolved: ResolvedSchedule
    private let clock = TestClock()
    private let events = RecordingInstrumentation()
    private let result = Mutex<Result<R, any Error>?>(nil)
    private let tag = LedgerTags.next()
    private let cancelRequested = Atomic<Bool>(false)
    // Sleeps on the simulation's clock begun by something other than the
    // driver: an unstructured task, a hop from another thread.
    private let outsideSleeps = Atomic<Int>(0)

    init(seed: UInt64, limits: SimulationLimits, faults: SimulatedFaults, schedule: SimulationSchedule, body: @escaping @Sendable (SimulationContext) async throws -> R) {
        self.seed = seed
        self.limits = limits
        self.faults = SeededFaults(seed: seed, settings: faults)
        self.body = body
        let resolved = ResolvedSchedule(schedule, seed: seed)
        self.resolved = resolved
        self.executor = SimulationExecutor(seed: seed, strategy: resolved.strategy)
        // A task the simulation does not drive that goes to sleep on its
        // clock must wake the driver: otherwise the driver, finding nothing
        // runnable and no sleeper yet, waits out its patience and calls the
        // run stalled while the sleeper it needs is already registered.
        clock.observeSleeps { [weak self] in
            if let self, !executor.isOnDriverThread {
                outsideSleeps.add(1, ordering: .relaxed)
                executor.wake()
            }
        }
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
        var earlyTimers = resolved.earlyTimers

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
            // Time may pass while work is still runnable: the next timer fires
            // early, on some seeds, a bounded number of times — a timeout
            // that lands in the middle of a computation. Never while outside
            // work is outstanding, which time waits for.
            if failure == nil, earlyTimers.budget > 0, executor.runnableCount > 0, clock.sleeperCount > 0,
               earlyTimers.roll(), !ExternalWork.isOutstanding(tag: tag), let now = clock.fireNextDeadline() {
                earlyTimers.budget -= 1
                fingerprint.mix(0xE471)
                fingerprint.mix(UInt64(truncatingIfNeeded: start.duration(to: now).attoseconds))
                if start.duration(to: now) > limits.virtualTime { fail(.virtualTimeLimit) }
                continue
            }
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
            // taken part in this run, nothing is likely to start now. Only
            // silence counts: a job arriving, or anything outside registering
            // on the clock, wakes the driver and the window starts again.
            let outside = executor.outsideArrivals > 0 || outsideSleeps.load(ordering: .relaxed) > 0 || ExternalWork.isOutstanding(tag: tag)
            let patience = outside ? limits.stall : min(limits.quietStall, limits.stall)
            if executor.waitForArrival(within: patience) { continue }
            // A quiet window is real time, and real time is load: a busy
            // machine may not have started a task of the app's in fifty
            // milliseconds. Before calling the run stalled, prove the
            // thread pools are answering, and give what they had queued
            // one last moment to arrive.
            if !outside, failure == nil, executor.waitForPoolsToAnswer(within: limits.stall),
               executor.waitForArrival(within: max(.milliseconds(5), limits.quietStall / 10)) { continue }
            if failure != nil { break }
            fail(.stalled(TaskLedger.entries(tag: tag)))
        }

        let elapsed = start.duration(to: clock.now)
        // What the run left behind, before it is cleaned up.
        let leftover = TaskLedger.entries(tag: tag)
        let outsideJobs = executor.outsideArrivals
        let outsideSleepCount = outsideSleeps.load(ordering: .relaxed)
        let stuck = unwind(task)
        if let failure {
            return .failure(SimulationFailure(kind: failure, seed: seed, steps: steps, elapsed: elapsed, fingerprint: fingerprint.value, schedule: resolved.description))
        }
        switch self.result.withLock({ $0 }) {
        case .success(let value)?:
            return .success(Simulated(
                value: value, seed: seed, steps: steps, elapsed: elapsed,
                fingerprint: fingerprint.value, schedule: resolved.description, leftover: leftover, stuck: stuck,
                faultsFired: faults.fired,
                report: SimulationReport(outsideJobs: outsideJobs, outsideSleeps: outsideSleepCount, leftover: leftover, stuck: stuck)
            ))
        case .failure(let error)?:
            return .failure(SimulationFailure(kind: .threw(error), seed: seed, steps: steps, elapsed: elapsed, fingerprint: fingerprint.value, schedule: resolved.description))
        case nil:
            return .failure(SimulationFailure(kind: .stalled(TaskLedger.entries(tag: tag)), seed: seed, steps: steps, elapsed: elapsed, fingerprint: fingerprint.value, schedule: resolved.description))
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

/// A schedule with every seeded choice made: the strategy, and how often
/// timers fire early.
struct ResolvedSchedule: Sendable {
    enum Strategy: Sendable, Hashable {
        case uniform
        case pct(depth: Int, horizon: Int)
    }

    let strategy: Strategy
    let earlyTimers: EarlyTimers

    /// The portfolio, by seed: half uniform, half PCT at depths two to four.
    /// Contiguous seeds cover it evenly, and the PCT seeds come early.
    private static let portfolio: [Strategy?] = [nil, nil, nil, .pct(depth: 2, horizon: 0), nil, .pct(depth: 3, horizon: 0), nil, .pct(depth: 4, horizon: 0)]

    init(_ schedule: SimulationSchedule, seed: UInt64) {
        // Separate streams, so choosing one never shifts another.
        var chooser = SplitMix(seed: seed ^ 0x5CED_01E5_C0DE_0001)
        func horizon(_ forced: Int?) -> Int {
            // No way to know how long a run is before it runs: a magnitude
            // from sixteen steps to eight thousand, by the seed.
            max(2, forced ?? 16 << Int(chooser.next() % 10))
        }
        switch schedule.strategy {
        case .uniform:
            strategy = .uniform
        case .pct(let depth, let forced):
            strategy = .pct(depth: max(2, depth), horizon: horizon(forced))
        case .portfolio:
            if case .pct(let depth, _)? = Self.portfolio[Int(seed % UInt64(Self.portfolio.count))] {
                strategy = .pct(depth: depth, horizon: horizon(nil))
            } else {
                strategy = .uniform
            }
        }
        if schedule.earlyTimers {
            var timers = SplitMix(seed: seed ^ 0x71EE_5000_C0DE_0002)
            let draw = timers.next()
            // Half the seeds keep time to the quiet moments.
            earlyTimers = draw & 1 == 0 ? .never : EarlyTimers(oneIn: [8, 32, 128][Int((draw >> 1) % 3)], random: timers)
        } else {
            earlyTimers = .never
        }
    }

    var description: String {
        var text: String
        switch strategy {
        case .uniform: text = "uniform"
        case .pct(let depth, let horizon): text = "pct(depth \(depth), horizon \(horizon))"
        }
        if let oneIn = earlyTimers.oneIn { text += ", early timers 1 in \(oneIn)" }
        return text
    }
}

/// When a timer fires while jobs are still runnable: a seeded chance at
/// every step, spent from a small budget so that progress is never starved.
struct EarlyTimers: Sendable {
    static let never = EarlyTimers(oneIn: nil, random: SplitMix(seed: 0))

    let oneIn: Int?
    private var random: SplitMix
    var budget: Int

    init(oneIn: Int?, random: SplitMix) {
        self.oneIn = oneIn
        self.random = random
        self.budget = oneIn == nil ? 0 : 32
    }

    mutating func roll() -> Bool {
        guard let oneIn else { return false }
        return random.next() % UInt64(oneIn) == 0
    }
}

/// A task executor that queues jobs and lets its driver run them one at a
/// time, choosing the next from a seed: uniformly, or by PCT priorities.
final class SimulationExecutor: TaskExecutor {
    private struct Entry {
        var job: UnownedJob
        var arrival: UInt64
        var priority: UInt64
        /// The task the job belongs to; `nil` for a job that is not a task's
        /// (an actor draining its mailbox).
        var task: UInt64?
    }

    private struct State {
        var jobs: [Entry] = []
        var arrivals: UInt64 = 0
        var random: SplitMix
        var pct: PCT?
        // The driver's thread, once it starts, and whether any job has been
        // enqueued from another one since.
        var driverThread: UInt64?
        var outsideArrivals = 0
    }

    /// PCT's bookkeeping. `State.jobs` is a max-heap by priority while it is
    /// in use.
    fileprivate struct PCT {
        var random: SplitMix
        var priorities: [UInt64: UInt64] = [:]
        /// Pick number to the priority the task picked then is demoted to.
        var changePoints: [Int: UInt64] = [:]
        var picks = 0
        /// The task whose job is running, and how many picks in a row were
        /// its own.
        var running: UInt64?
        var streak = 0
    }

    /// How many picks in a row a task may take, re-enqueuing itself each
    /// time (`Task.yield` takes two picks), before the yield demotes it. Pure demotion at
    /// the first yield turns PCT into round-robin for tasks that yield, and
    /// a bug that needs one task to run twenty yields ahead of another can
    /// no longer be found; none would let a spin-wait starve the task it
    /// waits for.
    static let spinLimit = 256

    private let state: Mutex<State>
    // Signalled on every arrival, so a driver with nothing to run can wait
    // for work from outside the simulation without spinning.
    private let arrival = DispatchSemaphore(value: 0)
    private let wantsIdentity: Bool

    init(seed: UInt64, strategy: ResolvedSchedule.Strategy) {
        var initial = State(random: SplitMix(seed: seed))
        switch strategy {
        case .uniform:
            wantsIdentity = false
        case .pct(let depth, let horizon):
            wantsIdentity = true
            var pct = PCT(random: SplitMix(seed: seed ^ 0xBC70_0000_0000_0003))
            for k in 1..<depth {
                // Distinct pick numbers; a collision moves to the next free one.
                var pick = 1 + Int(pct.random.next() % UInt64(horizon))
                while pct.changePoints[pick] != nil { pick += 1 }
                pct.changePoints[pick] = UInt64(k)
            }
            initial.pct = pct
        }
        state = Mutex(initial)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let thread = currentThreadID()
        // The task's identity is read from the job's description, outside the lock.
        let identity = wantsIdentity ? JobIdentity(job) : .unknown
        state.withLock { state in
            if let driver = state.driverThread, driver != thread { state.outsideArrivals += 1 }
            state.arrivals += 1
            var entry = Entry(job: job, arrival: state.arrivals, priority: 0, task: nil)
            if state.pct != nil {
                let onDriver = state.driverThread == thread
                let owner: UInt64?
                switch identity {
                case .unknown where state.jobs.isEmpty && state.arrivals == 1:
                    // The runtime's description is not what this expects:
                    // choose uniformly rather than guess.
                    state.pct = nil
                    owner = nil
                case .task(let id):
                    owner = id
                case .actor, .unknown:
                    // Not a task's own job: an actor draining its mailbox, or
                    // what `Task.yield` queues to resume the task. When the
                    // job running now queues it, it belongs to that task's
                    // thread of work and takes its priority.
                    owner = onDriver ? state.pct?.running : nil
                }
                if state.pct != nil {
                    if let owner {
                        entry.task = owner
                        entry.priority = state.pct!.priority(of: owner, enqueuedByItself: onDriver)
                    } else {
                        entry.priority = state.pct!.freshPriority()
                    }
                }
            }
            state.jobs.append(entry)
            if state.pct != nil { Self.siftUp(&state.jobs, state.jobs.count - 1) }
        }
        arrival.signal()
    }

    /// Marks the calling thread as the driver. Jobs enqueued from any other
    /// thread after this are work from outside the simulation.
    func beginDriving() {
        let thread = currentThreadID()
        state.withLock { $0.driverThread = thread }
    }

    /// How many jobs have arrived from a thread other than the driver's.
    var outsideArrivals: Int {
        state.withLock { $0.outsideArrivals }
    }

    /// Whether the calling thread is the driver's.
    var isOnDriverThread: Bool {
        let thread = currentThreadID()
        return state.withLock { $0.driverThread == thread }
    }

    /// How many jobs are runnable.
    var runnableCount: Int {
        state.withLock { $0.jobs.count }
    }

    /// Removes the next job to run. Also returns its arrival number and how
    /// many were runnable, for the fingerprint: the arrival number tells two
    /// runs apart that chose the same index from queues in different orders.
    func takeNext() -> (UnownedJob, UInt64, Int)? {
        state.withLock { state in
            guard !state.jobs.isEmpty else { return nil }
            let count = state.jobs.count
            let entry: Entry
            if state.pct != nil {
                entry = Self.popMax(&state.jobs)
                state.pct!.picked(entry.task)
            } else {
                let index = Int(state.random.next() % UInt64(count))
                state.jobs.swapAt(index, count - 1)
                entry = state.jobs.removeLast()
            }
            return (entry.job, entry.arrival, count)
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

    /// Waits up to `limit` of real time for the cooperative thread pool to run
    /// a trivial task: proof that a task the app started a moment ago has
    /// had its chance to run, even on a machine that is busy. Called from the
    /// driver's own thread, outside any task, so the probe has no executor
    /// preference and goes where an app's unstructured `Task {}` goes.
    func waitForPoolsToAnswer(within limit: Duration) -> Bool {
        let answered = DispatchSemaphore(value: 0)
        Task { answered.signal() }
        let (seconds, attoseconds) = limit.components
        let nanoseconds = Int(min(max(seconds, 0), 86_400)) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        return answered.wait(timeout: .now() + .nanoseconds(nanoseconds)) == .success
    }

    /// Wakes a driver waiting for arrivals, to notice a cancellation.
    func wake() {
        arrival.signal()
    }

    // MARK: Max-heap by priority, then by arrival (earlier first)

    private static func before(_ a: Entry, _ b: Entry) -> Bool {
        a.priority != b.priority ? a.priority > b.priority : a.arrival < b.arrival
    }

    private static func siftUp(_ heap: inout [Entry], _ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard before(heap[child], heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func popMax(_ heap: inout [Entry]) -> Entry {
        heap.swapAt(0, heap.count - 1)
        let top = heap.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1, right = left + 1
            var best = parent
            if left < heap.count, before(heap[left], heap[best]) { best = left }
            if right < heap.count, before(heap[right], heap[best]) { best = right }
            if best == parent { break }
            heap.swapAt(parent, best)
            parent = best
        }
        return top
    }
}

extension SimulationExecutor {
    /// Which task a job belongs to.
    ///
    /// The runtime offers no API for it. `UnownedJob.description` is
    /// `UnownedJob(id: 12)` for a task's job and `UnownedJob(id: nil)` for
    /// one that is not (an actor draining its mailbox). This is the only
    /// place that reads it; if the format ever changes, the first job
    /// reads as `unknown` and PCT falls back to uniform choice.
    enum JobIdentity: Equatable {
        case task(UInt64)
        case actor
        case unknown

        init(_ job: UnownedJob) {
            self.init(description: job.description)
        }

        init(description text: String) {
            guard let marker = text.firstRange(of: "id: ") else {
                self = .unknown
                return
            }
            let rest = text[marker.upperBound...]
            if rest.hasPrefix("nil") {
                self = .actor
            } else if let id = UInt64(rest.prefix { $0.isASCII && $0.isNumber }) {
                self = .task(id)
            } else {
                self = .unknown
            }
        }
    }
}

extension SimulationExecutor.PCT {
    /// A priority above every demoted one.
    mutating func freshPriority() -> UInt64 {
        random.next() | (1 << 40)
    }

    /// The priority a task's next job queues with.
    mutating func priority(of task: UInt64, enqueuedByItself: Bool) -> UInt64 {
        if priorities[task] == nil { priorities[task] = freshPriority() }
        // It is the one running, and it queued itself again: it yielded. A
        // long streak of that is a spin-wait; give way to everyone else.
        if enqueuedByItself, running == task, streak >= SimulationExecutor.spinLimit {
            priorities[task] = 0   // below even the change points' demotions
            streak = 0
        }
        return priorities[task]!
    }

    mutating func picked(_ task: UInt64?) {
        picks += 1
        if task != nil, task == running { streak += 1 } else { streak = 1 }
        running = task
        if let task, let demoted = changePoints[picks] { priorities[task] = demoted }
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
