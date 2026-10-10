import Dispatch
@testable import Stoic
import StoicTesting
import Testing

@Suite("Abandoning timeouts", .serialized)
struct AbandoningTests {
    enum Failure: Error, Equatable { case boom }

    /// A label unique to one test run: the ledger is process-wide, and a
    /// repeated test must not inherit the previous run's abandoned work.
    static func uniqueLabel(_ base: String) -> String {
        "\(base).\(IdempotencyKey.random().rawValue.prefix(8))"
    }

    /// A blocking call that returns only when released: the wedged system call.
    final class Wedge: Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        func block() { semaphore.wait() }   // stoic:allow(blocking-in-async): models a wedged synchronous call, on a Dispatch thread
        func release() { semaphore.signal() }
    }

    @Test func fastWorkReturnsItsResult() async throws {
        let value = try await abandoningAfter(.seconds(5), label: "fast") { () throws(Failure) -> Int in 42 }
        #expect(value == 42)
        await #expect(throws: PolicyError<Failure>.self) {
            try await abandoningAfter(.seconds(5), label: "fast") { () throws(Failure) -> Int in throw .boom }
        }
    }

    @Test func wedgedWorkIsAbandonedAtTheDeadline() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let wedge = Wedge()
        defer { wedge.release() }
        let label = Self.uniqueLabel("audio.start")
        let task = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await abandoningAfter(.seconds(2), label: label) { () throws(Failure) -> Int in
                    wedge.block()
                    return 1
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(2))
        do {
            _ = try await task.value
            Issue.record("expected the work to be abandoned")
        } catch let error as PolicyError<Failure> {
            #expect(error.rejection?.reason == .deadlineExceeded)
        }
        #expect(AbandonedWork.current.contains { $0.label == label })
        #expect(events.names.contains("abandoned.started"))
        wedge.release()
        for _ in 0..<1_000 where AbandonedWork.current.contains(where: { $0.label == label }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!AbandonedWork.current.contains { $0.label == label })
    }

    @Test func aWedgedLabelRefusesNewWork() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let wedge = Wedge()
        defer { wedge.release(); wedge.release() }
        let label = Self.uniqueLabel("ax.hung")
        try await withTestAmbient(clock: clock, events: events) {
            for _ in 0..<2 {
                async let attempt: Int = abandoningAfter(.seconds(1), label: label, limit: 2) { () throws(Failure) -> Int in
                    wedge.block()
                    return 1
                }
                await clock.waitForSleepers(count: 1)
                await clock.advance(by: .seconds(1))
                _ = try? await attempt
            }
            do {
                _ = try await abandoningAfter(.seconds(1), label: label, limit: 2) { () throws(Failure) -> Int in 1 }
                Issue.record("expected the wedged label to refuse")
            } catch let error as PolicyError<Failure> {
                #expect(error.rejection?.reason == .abandonmentLimit)
            }
        }
        #expect(events.names.contains("abandoned.wedged"))
    }

    @Test func concurrentCallersNeverOccupyMoreThanTheLimit() async throws {
        let clock = TestClock()
        let wedge = Wedge()
        defer { for _ in 0..<12 { wedge.release() } }
        let label = Self.uniqueLabel("ax.concurrent")
        let started = SendableBox(0)
        let reasons = try await withTestAmbient(clock: clock) {
            try await withThrowingTaskGroup(of: Rejection.Reason?.self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        do {
                            _ = try await abandoningAfter(.seconds(1), label: label, limit: 2) { () throws(Failure) -> Int in
                                started.mutate { $0 += 1 }
                                wedge.block()
                                return 1
                            }
                            return nil
                        } catch let error as PolicyError<Failure> {
                            return error.rejection?.reason
                        }
                    }
                }
                // Two running calls wait on their timers, ten on a slot.
                await clock.waitForSleepers(count: 12)
                await clock.advance(by: .seconds(1))
                return try await group.reduce(into: [Rejection.Reason?]()) { $0.append($1) }
            }
        }
        // Abandonment is recorded before each call returns, so this count is exact.
        #expect(AbandonedWork.current.filter { $0.label == label }.count == 2, "only `limit` operations may occupy threads")
        // The operations themselves run on Dispatch threads: let any that
        // were (wrongly) dispatched get there before counting.
        #expect(await eventually { started.value >= 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(started.value == 2)
        #expect(reasons.allSatisfy { $0 == .deadlineExceeded })
    }

    @Test func anAlreadyCancelledCallerStartsNothing() async throws {
        let ran = SendableBox(false)
        let label = Self.uniqueLabel("cancelled.first")
        let task = Task {
            try? await Task.sleep(for: .seconds(3600))   // returns at once: the task is cancelled
            return try await abandoningAfter(.seconds(5), label: label) { () throws(Failure) -> Int in
                ran.mutate { $0 = true }
                return 1
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected a refusal")
        } catch let error as PolicyError<Failure> {
            #expect(error.rejection?.reason == .cancelled)
        }
        try await Task.sleep(for: .milliseconds(50))   // time for a wrongly dispatched operation to run
        #expect(ran.value == false)
    }

    @Test func aPassedDeadlineStartsNothing() async throws {
        let clock = TestClock()
        let ran = SendableBox(false)
        let label = Self.uniqueLabel("late")
        try await withTestAmbient(clock: clock) {
            let passed = Deadline(clock.erased.now, clock: clock.erased)
            try await Deadline.$stored.withValue(passed) {
                do {
                    _ = try await abandoningAfter(.seconds(5), label: label) { () throws(Failure) -> Int in
                        ran.mutate { $0 = true }
                        return 1
                    }
                    Issue.record("expected a refusal")
                } catch let error as PolicyError<Failure> {
                    #expect(error.rejection?.reason == .deadlineExceeded)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))   // time for a wrongly dispatched operation to run
        #expect(ran.value == false)
    }

    @Test func cancellingTheCallerAbandonsTheWork() async throws {
        let wedge = Wedge()
        defer { wedge.release() }
        let label = Self.uniqueLabel("cancel")
        let task = Task {
            try await abandoningAfter(.seconds(3600), label: label) { () throws(Failure) -> Int in
                wedge.block()
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as PolicyError<Failure> {
            #expect(error.rejection?.reason == .cancelled)
        }
    }
}
