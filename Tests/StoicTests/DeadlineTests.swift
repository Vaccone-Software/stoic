import Foundation
@testable import Stoic
import StoicTesting
import Testing

@Suite("Deadlines")
struct DeadlineTests {
    enum Failure: Error, Equatable { case boom }

    @Test(.failureMode("design/01", "the operation finishes first")) func anOperationThatFinishesFirstReturnsAndStopsTheTimer() async throws {
        let clock = TestClock()
        let value = try await withTestAmbient(clock: clock) {
            try await withTimeout(.seconds(5)) { () throws(Failure) -> Int in 42 }
        }
        #expect(value == 42)
        #expect(clock.sleeperCount == 0, "the timer must not outlive the operation")
    }

    @Test func aTypedErrorPassesThrough() async {
        await #expect(throws: Failure.boom) {
            try await withTimeout(.seconds(5)) { () throws(Failure) -> Int in throw .boom }
        }
    }

    @Test(.failureMode("design/01", "the deadline passes, operation honours cancellation")) func anExpiredDeadlineCancelsTheOperationWithACause() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let observed = SendableBox<CancellationCause?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await withTimeout(.seconds(2), label: "fetch") {
                    do {
                        try await Ambient.sleep(for: .seconds(60))
                    } catch {
                        observed.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(2))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .deadline)
        let expired = events.events(named: "deadline.expired")
        #expect(expired.count == 1)
        #expect(expired.first?.label == "fetch")
    }

    /// The Mac sleeps with a thirty-second timeout pending and wakes an hour
    /// later: the continuous clock counted the sleep, so the clock "jumps".
    @Test(.failureMode("design/01", "the Mac sleeps past the deadline")) func aClockJumpPastTheDeadlineFiresItAtOnce() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let observed = SendableBox<CancellationCause?>(nil)
        let deadline = await withTestAmbient(clock: clock) { Deadline.after(.seconds(30)) }
        #expect(!deadline.hasPassed)
        let task = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await withTimeout(.seconds(30), label: "sleepy") {
                    do {
                        try await Ambient.sleep(for: .seconds(3600))
                    } catch {
                        observed.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(3600))   // one jump: no tick in between
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .deadline)
        #expect(deadline.hasPassed)
        #expect(deadline.remaining == .zero)
        let expired = events.events(named: "deadline.expired")
        #expect(expired.count == 1)
        #expect(clock.sleeperCount == 0)
    }

    @Test(.failureMode("design/01", "the deadline passes, operation ignores cancellation (cooperative)")) func anOperationThatIgnoresCancellationIsAwaited() async throws {
        let clock = TestClock()
        let gate = AsyncGate()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) { () throws(Failure) -> String in
                    await gate.wait()   // not cancellation-aware
                    return "late"
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(1))
        gate.open()
        #expect(try await task.value == "late")
    }

    @Test(.failureMode("design/01", "the caller is cancelled")) func cancellingTheCallerCancelsTheOperationAsUserRequested() async {
        let clock = TestClock()
        let observed = SendableBox<CancellationCause?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(60)) {
                    do {
                        try await Ambient.sleep(for: .seconds(30))
                    } catch {
                        observed.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .userRequested)
    }

    @Test(.failureMode("design/01", "an inner timeout is longer than the outer deadline")) func anOuterDeadlineIsTheCauseInsideAnInnerScope() async {
        let clock = TestClock()
        let observed = SendableBox<CancellationCause?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) {
                    try await withTimeout(.seconds(30)) {
                        do {
                            try await Ambient.sleep(for: .seconds(60))
                        } catch {
                            observed.mutate { $0 = CancellationCause.current }
                            throw error
                        }
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)   // the outer timer and the operation: the inner adds none
        await clock.advance(by: .seconds(1))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .deadline)
    }

    /// The inner timeout cannot narrow the outer deadline, so it is a no-op:
    /// no timer of its own, and the expiry is the outer scope's alone.
    @Test(.failureMode("design/01", "an inner timeout is longer than the outer deadline")) func aNoOpInnerTimeoutAddsNoTimerAndReportsNothing() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let task = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await withTimeout(.seconds(1), label: "outer") {
                    try await withTimeout(.seconds(30), label: "inner") {
                        try await Ambient.sleep(for: .seconds(60))
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        #expect(clock.sleeperCount == 2, "the inner timeout must not add a timer")
        await clock.advance(by: .seconds(1))
        _ = try? await task.value
        #expect(events.events(named: "deadline.expired").map(\.label) == ["outer"])
    }

    /// A retry's attempt timeout that the enclosing deadline already bounds
    /// is not reported as an attempt that timed out: the whole call ran out
    /// of time, which the retry learns from the deadline, not the attempt.
    @Test func aDeadlineThatCannotNarrowIsNotReportedAsExpired() async {
        let clock = TestClock()
        let expired = SendableBox<Bool?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) {
                    let outcome = await runWithDeadline(.after(.seconds(30)), tolerance: nil, label: "attempt", fileID: #fileID, line: #line) {
                        try await Ambient.sleep(for: .seconds(60))
                    }
                    expired.mutate { $0 = outcome.expired }
                    try outcome.result.get()
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(1))
        _ = try? await task.value
        #expect(expired.value == false)
    }

    /// Entered after the enclosing deadline passed, a deadline that cannot
    /// narrow it still runs the operation cancelled, with the deadline as
    /// the cause, and leaves the report to the enclosing scope.
    @Test func aNoOpDeadlineEnteredAfterTheEnclosingOnePassedRunsCancelled() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let passed = Deadline(clock.erased.now, clock: clock.erased)
        let (cancelled, cause) = await withTestAmbient(clock: clock, events: events) {
            await Deadline.$stored.withValue(passed) {
                await withTimeout(.seconds(30), label: "inner") { () async -> (Bool, CancellationCause?) in
                    (Task.isCancelled, CancellationCause.current)
                }
            }
        }
        #expect(cancelled)
        #expect(cause == .deadline)
        #expect(events.events(named: "deadline.expired").isEmpty)
    }

    /// Random nestings of `withDeadline` and `withTimeout` on the virtual
    /// clock: every level sees the tightest deadline so far and never a
    /// later one, only the levels that narrow it start a timer, and when it
    /// passes exactly one expiry is reported, by the outermost level that set it.
    @Test(.stoic(seed: 61), .timeLimit(.minutes(1)), arguments: Array(0..<25))
    func randomNestingsUseTheTightestDeadlineAndBlameItsOwner(round: Int) async {
        struct Level: Sendable, CustomStringConvertible {
            let label: String
            let seconds: Int64
            let asDeadline: Bool
            var description: String { "\(label): \(asDeadline ? "deadline" : "timeout") \(seconds)s" }
        }
        var generator = Ambient.current.random.generator(discriminator: UInt64(round))
        for attempt in 0..<(4 * testScale) {
            let levels = (0..<Int.random(in: 1...6, using: &generator)).map { index in
                Level(label: "L\(index)", seconds: Int64.random(in: 1...8, using: &generator), asDeadline: Bool.random(using: &generator))
            }
            let tightest = levels.map(\.seconds).min()!
            let owner = levels.first { $0.seconds == tightest }!.label
            var narrowing = 0
            var smallest = Int64.max
            for level in levels where level.seconds < smallest {
                narrowing += 1
                smallest = level.seconds
            }
            let context = "round \(round).\(attempt): \(levels)"

            let clock = TestClock()
            let events = RecordingInstrumentation()
            let seen = SendableBox<[String]>([])
            let cause = SendableBox<CancellationCause?>(nil)
            @Sendable func nest(_ remaining: ArraySlice<Level>, tightestSoFar: Int64) async throws {
                guard let level = remaining.first else {
                    do { try await Ambient.sleep(for: .seconds(3600)) } catch {
                        cause.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                    return
                }
                let expected = min(tightestSoFar, level.seconds)
                let body: @Sendable () async throws -> Void = {
                    let offset = Deadline.current.map { clock.erased.now.duration(to: $0.instant) }
                    if offset != .seconds(expected) {
                        seen.mutate { $0.append("\(level.label) saw \(String(describing: offset)), expected \(expected)s") }
                    }
                    try await nest(remaining.dropFirst(), tightestSoFar: expected)
                }
                if level.asDeadline {
                    try await withDeadline(.after(.seconds(level.seconds)), label: level.label) { try await body() }
                } else {
                    try await withTimeout(.seconds(level.seconds), label: level.label) { try await body() }
                }
            }
            let task = Task {
                try await withTestAmbient(clock: clock, events: events) {
                    try await nest(levels[...], tightestSoFar: .max)
                }
            }
            await clock.waitForSleepers(count: narrowing + 1)
            #expect(clock.sleeperCount == narrowing + 1, "one timer per narrowing level: \(context)")
            await clock.advance(by: .seconds(tightest))
            _ = try? await task.value

            #expect(seen.value.isEmpty, "\(seen.value) in \(context)")
            #expect(cause.value == .deadline, "\(context)")
            #expect(events.events(named: "deadline.expired").map(\.label) == [owner], "\(context)")
        }
    }

    @Test(.failureMode("design/01", "an inner timeout is longer than the outer deadline")) func nestedDeadlinesNarrowAndNeverWiden() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock) {
            try await withTimeout(.seconds(2)) {
                let outer = try #require(Deadline.current)
                try await withTimeout(.seconds(30)) {
                    let inner = try #require(Deadline.current)
                    #expect(inner.instant == outer.instant)
                }
                try await withTimeout(.seconds(1)) {
                    let inner = try #require(Deadline.current)
                    #expect(inner.instant < outer.instant)
                }
            }
        }
    }

    @Test(.failureMode("design/01", "the deadline has already passed on entry")) func anAlreadyPassedDeadlineRunsTheOperationCancelled() async throws {
        let clock = TestClock()
        let deadline = Deadline(clock.erased.now, clock: clock.erased)
        let wasCancelled = try await withTestAmbient(clock: clock) {
            try await withDeadline(deadline) { () throws(Failure) -> Bool in Task.isCancelled }
        }
        #expect(wasCancelled)
    }

    @Test @MainActor func theOperationRunsOnTheCallersActor() async throws {
        final class Counter { var value = 0 }
        let counter = Counter()
        try await withTimeout(.seconds(5)) { () throws(Failure) in
            MainActor.assertIsolated()
            counter.value += 1
        }
        #expect(counter.value == 1)
    }

    /// No cancellation handler in Stoic records `.userRequested` outright:
    /// one that does writes over the cause an enclosing scope recorded
    /// before it cancelled (a task scope under an expiring deadline once
    /// told its body "the user cancelled"). Handlers record
    /// `CancellationCauseBox.outsideCause(seenBy:)`, which falls back to
    /// `.userRequested` only when no enclosing scope recorded a cause.
    @Test func noCancellationHandlerRecordsUserRequestedOverAnEnclosingCause() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("record(.userRequested)") || line.contains("cause: .userRequested") {
                offenders.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "record CancellationCauseBox.outsideCause(seenBy:) instead:\n\(offenders.joined(separator: "\n"))")
    }

    @Test func remainingIsZeroOncePassed() async {
        let clock = TestClock()
        let deadline = Deadline.after(.seconds(3), clock: clock.erased)
        #expect(deadline.remaining == .seconds(3))
        await clock.advance(by: .seconds(5))
        #expect(deadline.remaining == .zero)
        #expect(deadline.hasPassed)
    }
}

/// A one-shot gate that ignores cancellation: models work that cannot be interrupted.
final class AsyncGate: Sendable {
    private let state = SendableBox<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.mutate { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Tasks suspended at the gate right now.
    var waiterCount: Int { state.value.waiters.count }

    func open() {
        let waiters = state.mutate { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

@Suite("Expiring work")
struct ExpiringWorkTests {
    /// Runs `expiring.run` in a task whose work records why it stopped.
    static func blockedRun(
        _ expiring: ExpiringWork,
        within limit: Duration? = nil,
        observed: SendableBox<CancellationCause?>,
        started: AsyncGate
    ) -> Task<Void, any Error> {
        Task {
            try await expiring.run(within: limit) {
                started.open()
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    observed.mutate { $0 = CancellationCause.current }
                    throw error
                }
            }
        }
    }

    @Test func expiryCancelsTheWorkAndSaysWhy() async {
        let expiring = ExpiringWork()
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        let task = Self.blockedRun(expiring, observed: observed, started: started)
        await started.wait()
        expiring.expire()   // no task.cancel(): expiry alone must reach the work
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .systemExpiring)
    }

    @Test func cancellingTheCallerReachesTheWork() async {
        let expiring = ExpiringWork()
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        let task = Self.blockedRun(expiring, observed: observed, started: started)
        await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observed.value == .userRequested)
        #expect(!expiring.isExpired)
    }

    @Test func theGrantedTimeIsTheWorksDeadline() async {
        let clock = TestClock()
        let observed = SendableBox<CancellationCause?>(nil)
        let sawDeadline = SendableBox(false)
        await withTestAmbient(clock: clock) {
            let expiring = ExpiringWork()
            let task = Task {
                try await expiring.run(within: .seconds(30)) {
                    sawDeadline.mutate { $0 = Deadline.current != nil }
                    do { try await clock.sleep(for: .seconds(3600)) } catch {
                        observed.mutate { $0 = CancellationCause.current }
                        throw error
                    }
                }
            }
            await clock.waitForSleepers(count: 2)   // the work, and its deadline
            await clock.advance(by: .seconds(30))
            await #expect(throws: (any Error).self) { try await task.value }
        }
        #expect(sawDeadline.value)
        #expect(observed.value == .deadline)
    }

    @Test func expiryIsFinal() async {
        let expiring = ExpiringWork()
        expiring.expire()
        let ran = SendableBox(false)
        await #expect(throws: CancellationError.self) {
            try await expiring.run { ran.mutate { $0 = true } }
        }
        #expect(!ran.value)
    }

    @Test func runsDoNotShareACause() async throws {
        // One run cancelled by its caller must not make a later run's
        // unrelated cancellation read differently, nor the reverse.
        let expiring = ExpiringWork()
        for _ in 0..<2 {
            let observed = SendableBox<CancellationCause?>(nil)
            let started = AsyncGate()
            let task = Self.blockedRun(expiring, observed: observed, started: started)
            await started.wait()
            task.cancel()
            _ = await task.result
            #expect(observed.value == .userRequested)
        }
    }

    @Test(arguments: [
        (Double.greatestFiniteMagnitude, nil),   // UIKit, in the foreground
        (.infinity, nil), (.nan, nil), (0, nil), (-1, nil), (3601, nil),
        (29.5, Duration.milliseconds(29_500)), (3600, .seconds(3600)),
    ] as [(Double, Duration?)])
    func hostSecondsBecomeALimitOnlyWhenTheyAreOne(seconds: Double, limit: Duration?) {
        #expect(ExpiringWork.limit(fromSecondsRemaining: seconds) == limit)
    }
}
