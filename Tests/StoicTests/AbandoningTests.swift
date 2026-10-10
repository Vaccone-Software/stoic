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
