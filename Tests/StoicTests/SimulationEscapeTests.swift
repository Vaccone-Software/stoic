import Dispatch
@testable import Stoic
@testable import StoicTesting
import Synchronization
import Testing

enum EscapePhase: Hashable, Sendable { case idle, on }

struct EscapeScenarioError: Error, CustomStringConvertible {
    var description: String { "the scenario's own error" }
}

/// Work that leaves a simulation must be visible: reported on the run, and
/// recorded as a test issue unless the caller allows it (design/12).
@Suite("Simulation escapes")
struct SimulationEscapeTests {
    /// Runs `body`, which is expected to record issues, and returns their
    /// messages. The issues are known, so the test itself stays green.
    static func recordedIssues(_ body: () async throws -> Void) async rethrows -> [String] {
        let messages = Mutex<[String]>([])
        try await withKnownIssue(isIntermittent: true) {
            try await body()
        } matching: { issue in
            messages.withLock { $0.append(issue.comments.map(\.rawValue).joined(separator: "\n")) }
            return true
        }
        return messages.withLock { $0 }
    }

    /// Escaped work runs on real threads, and the machine may be busy: the
    /// first thing from outside has longer than the default fifty
    /// milliseconds to arrive.
    static let patient = SimulationLimits(stall: .seconds(10), quietStall: .seconds(5))

    // MARK: A clean run

    @Test func aRunInsideTheSimulationIsDeterministicAndRecordsNothing() async throws {
        // No allowEscapes: an issue here would fail the test.
        let run = try await simulate(seed: 4) { _ in
            try await Ambient.sleep(for: .seconds(5))
            return await withTaskGroup(of: Int.self) { group in
                for index in 0..<3 { group.addTask { index } }
                return await group.reduce(0, +)
            }
        }
        #expect(run.value == 3)
        #expect(run.isDeterministic)
        #expect(run.outsideArrivals == 0)
        #expect(run.report.leftover.isEmpty && run.report.stuck.isEmpty)
        #expect(!run.report.hasEscapes)
    }

    @Test func aTaskStartedWithTheAmbientExecutorIsNotAnEscape() async throws {
        let run = try await simulate(seed: 2) { _ in
            let task = Task(executorPreference: Ambient.current.taskExecutor) { () async throws -> Int in
                try await Ambient.sleep(for: .seconds(3))
                return 7
            }
            return try await task.value
        }
        #expect(run.value == 7)
        #expect(run.isDeterministic)
    }

    // MARK: Unstructured work that sleeps on the simulation's clock

    @Test(.timeLimit(.minutes(1))) func anUnstructuredTaskThatSleepsOnTheAmbientClockNoLongerStalls() async throws {
        // It used to stall every time: the task registers its sleeper from
        // another thread, the driver found none a moment earlier and waited
        // out its patience. The default 50 ms patience, then the long one.
        for limits in [SimulationLimits.standard, SimulationLimits(quietStall: .seconds(1))] {
            for seed in 0..<8 as Range<UInt64> {
                let run = try await simulate(seed: seed, limits: limits, allowEscapes: true) { _ in
                    let task = Task { () async throws -> Int in
                        try await Ambient.sleep(for: .seconds(3))
                        return 1
                    }
                    return try await task.value
                }
                #expect(run.value == 1)
                #expect(run.elapsed >= .seconds(3))
                #expect(run.report.outsideSleeps >= 1, "seed \(seed)")
                #expect(!run.isDeterministic)
            }
        }
    }

    @Test func anUnstructuredTaskThatSleepsOnTheAmbientClockIsReportedAsAnEscape() async throws {
        let issues = try await Self.recordedIssues {
            _ = try await simulate(seed: 1, limits: Self.patient) { _ in
                let task = Task { () async throws -> Int in
                    try await Ambient.sleep(for: .seconds(3))
                    return 1
                }
                return try await task.value
            }
        }
        #expect(issues.count == 1)
        let message = issues.first ?? ""
        #expect(message.contains("simulation with seed 1"))
        #expect(message.contains("work escaped the simulation"))
        // The likely causes, and the fix.
        #expect(message.contains("unstructured Task"))
        #expect(message.contains("Task.detached"))
        #expect(message.contains("DispatchQueue"))
        #expect(message.contains("Timer"))
        #expect(message.contains("real clock"))
        #expect(message.contains("Ambient.current.taskExecutor"))
        #expect(message.contains("Ambient.sleep(for:)"))
        #expect(message.contains("allowEscapes: true"))
    }

    // MARK: Other escapes

    @Test func aDetachedTaskOnARealClockIsReported() async throws {
        let run = try await simulate(seed: 0, limits: Self.patient, allowEscapes: true) { _ in
            let task = Task.detached { () async throws -> Int in
                try await Task.sleep(for: .milliseconds(5))
                return 2
            }
            return try await task.value
        }
        #expect(run.value == 2)
        #expect(run.report.outsideJobs >= 1)
        #expect(!run.isDeterministic)
    }

    @Test func dispatchIsReported() async throws {
        let run = try await simulate(seed: 0, limits: Self.patient, allowEscapes: true) { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { continuation.resume() }
            }
            return 3
        }
        #expect(run.value == 3)
        #expect(run.report.outsideJobs >= 1)
        #expect(!run.isDeterministic)
    }

    @Test func aRealClockSleepIsReported() async throws {
        let issues = try await Self.recordedIssues {
            _ = try await simulate(seed: 0, limits: Self.patient) { _ in
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(issues.count == 1)
    }

    @Test func workLeftRunningIsReportedAsALeak() async throws {
        let issues = try await Self.recordedIssues {
            _ = try await simulate(seed: 0, schedule: .uniform) { _ in
                let machine = StateMachine<EscapePhase, EscapePhase>(initial: .idle, label: "escape.leak") { _, to in .to(to) }
                machine.whileIn(.on, label: "humming") { _ in
                    try? await Ambient.sleep(for: .seconds(3600))
                }
                machine.send(.on)
                await Task.yield()
                return machine
            }
        }
        #expect(issues.count == 1)
        let message = issues.first ?? ""
        #expect(message.contains("escape.leak.humming"))
        #expect(message.contains("still running when the body returned"))
        #expect(message.contains("allowEscapes: true"))
    }

    @Test func allowEscapesSilencesTheIssueButNotTheReport() async throws {
        let run = try await simulate(seed: 0, limits: Self.patient, allowEscapes: true) { _ in
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(run.report.hasEscapes)
        #expect(run.report.description.contains("allowEscapes: true"))
        #expect(!run.isDeterministic)
    }

    @Test func aCleanReportSaysSo() async throws {
        let run = try await simulate(seed: 0) { _ in 1 }
        #expect(run.report.description.contains("nothing escaped"))
    }

    // MARK: The executor outlives an enqueue from outside

    /// Holds one enqueue from another thread open between "the job is
    /// queued" and "the driver is signalled".
    private final class Window: Sendable {
        let published = Atomic<Bool>(false)
        let armed = Atomic<Bool>(true)
        /// Signalled once the body has suspended, so the thread resumes it
        /// from outside rather than before it has waited.
        let suspended = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
    }

    /// A thread that is not the driver hands the executor its last job, and
    /// is slow to signal: the driver runs the job, the body ends, the run is
    /// over and its executor released, all inside that call. It used to
    /// signal the freed executor (a heap-use-after-free under Address
    /// Sanitizer, seen once in tens of thousands of runs under load).
    @Test func theExecutorOutlivesTheEnqueueThatHandsItsLastJobToTheDriver() async throws {
        let window = Window()
        let run = try await simulate(seed: 3, limits: Self.patient, allowEscapes: true) { _ in
            let executor = try #require(Ambient.current.taskExecutor as? SimulationExecutor)
            let driver = currentThreadID()
            executor.afterPublishing.withLock {
                $0 = .init {
                    guard currentThreadID() != driver, window.armed.exchange(false, ordering: .acquiringAndReleasing) else { return }
                    window.published.store(true, ordering: .releasing)
                    window.release.wait()
                }
            }
            // Keeps the driver running jobs, so it finds the one from outside
            // without anyone signalling it. It first runs when the body has
            // suspended.
            let spinner = Task(executorPreference: executor) {
                window.suspended.signal()
                while !window.published.load(ordering: .acquiring) { await Task.yield() }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    window.suspended.wait()
                    continuation.resume()
                    window.finished.signal()
                }
            }
            await spinner.value
            return 1
        }
        #expect(run.value == 1)
        window.release.signal()
        // The enqueue goes on to signal; the test ends only after it has.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                window.finished.wait()
                continuation.resume()
            }
        }
    }

    // MARK: Many seeds

    @Test func manySeedsRecordOneIssueNotOnePerSeed() async throws {
        let issues = try await Self.recordedIssues {
            try await simulate(seeds: 0..<12, limits: Self.patient) { _ in
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        #expect(issues.count == 1)
        #expect(issues.first?.contains("simulation with seed 0") == true)
        #expect(issues.first?.contains("the other 11 seeds") == true)
    }

    @Test func manySeedsMayAllowEscapes() async throws {
        try await simulate(seeds: 0..<3, limits: Self.patient, allowEscapes: true) { _ in
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: Failures print

    @Test func aFailureKindCanBePrinted() async throws {
        let threw = await #expect(throws: SimulationFailure.self) {
            _ = try await simulate(seed: 0) { _ in throw EscapeScenarioError() }
        }
        #expect(threw?.kind.name == "threw")
        #expect(String(describing: threw!.kind) == "threw the scenario's own error")

        let stalled = await #expect(throws: SimulationFailure.self) {
            _ = try await simulate(seed: 0, limits: .init(quietStall: .milliseconds(10))) { _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        #expect(stalled?.kind.name == "stalled")
        #expect(String(describing: stalled!.kind).hasPrefix("stalled"))

        let livelock = await #expect(throws: SimulationFailure.self) {
            _ = try await simulate(seed: 0, limits: .init(virtualTime: .seconds(10))) { _ in
                while true { try await Ambient.sleep(for: .seconds(1)) }
            }
        }
        #expect(livelock?.kind.name == "virtual time limit")
        #expect(String(describing: livelock!.kind) == "virtual time limit")
    }
}
