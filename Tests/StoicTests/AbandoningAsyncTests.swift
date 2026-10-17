@testable import Stoic
import StoicTesting
import Testing

@Suite("Abandoning async work", .serialized)
struct AbandoningAsyncTests {
    enum Failure: Error, Equatable { case boom }

    static func uniqueLabel(_ base: String) -> String { AbandoningTests.uniqueLabel(base) }

    /// Waits until `condition` holds, in real time: abandoned work finishes off the test clock.
    func settles(_ condition: () -> Bool) async -> Bool { await eventually(condition) }

    @Test func fastWorkReturnsItsResultAndItsFailure() async throws {
        let value = try await abandoningAsyncAfter(.seconds(5), label: "fast.async") { () async throws(Failure) -> Int in 42 }
        #expect(value == 42)
        await #expect(throws: PolicyError<Failure>.self) {
            try await abandoningAsyncAfter(.seconds(5), label: "fast.async") { () async throws(Failure) -> Int in throw .boom }
        }
    }

    @Test(.failureMode("design/01", "the deadline passes, async work ignores cancellation (abandoning)"),
          .failureMode("design/01", "abandoned async work finishes later"))
    func aContinuationThatNeverResumesIsAbandonedAtTheDeadline() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let callback = AsyncGate()   // the framework's completion handler, which does not come
        let label = Self.uniqueLabel("audio.start.async")
        let task = Task {
            try await withTestAmbient(clock: clock, events: events) {
                try await abandoningAsyncAfter(.seconds(2), label: label) { () async throws(Failure) -> Int in
                    await callback.wait()
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
        #expect(AbandonedWork.ledger.holdsSlots(label: label))   // still occupies its slot

        callback.open()
        #expect(await settles { !AbandonedWork.current.contains { $0.label == label } })
        #expect(await settles { events.names.contains("abandoned.completed") })
        #expect(await settles { !AbandonedWork.ledger.holdsSlots(label: label) })
    }

    @Test(.failureMode("design/01", "the deadline passes, async work checks cancellation (abandoning)"))
    func workThatChecksIsCancelledAtTheDeadlineWithCauseDeadline() async throws {
        let clock = TestClock()
        let causes = SendableBox<[CancellationCause?]>([])
        let label = Self.uniqueLabel("checks.async")
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await abandoningAsyncAfter(.seconds(2), label: label) { () async throws(Failure) -> Int in
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
                    causes.mutate { $0.append(CancellationCause.current) }
                    return 1
                }
            }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(2))
        do {
            _ = try await task.value
            Issue.record("expected a refusal")
        } catch let error as PolicyError<Failure> {
            #expect(error.rejection?.reason == .deadlineExceeded)
        }
        #expect(await settles { causes.value == [.deadline] })
        #expect(await settles { !AbandonedWork.current.contains { $0.label == label } })
    }

    @Test(.failureMode("design/01", "an async abandoning call is made from the main actor"))
    @MainActor func aMainActorCallerIsNotBlockedAndGetsTheDeadline() async throws {
        let clock = TestClock()
        let callback = AsyncGate()
        let label = Self.uniqueLabel("main.async")
        let result = await withTestAmbient(clock: clock) { () async -> Rejection.Reason? in
            async let attempt: Int = abandoningAsyncAfter(.seconds(1), label: label) { () async throws(Failure) -> Int in
                await callback.wait()
                return 1
            }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(1))
            do {
                _ = try await attempt
                return nil
            } catch let error as PolicyError<Failure> {
                return error.rejection?.reason
            } catch {
                return nil
            }
        }
        #expect(result == .deadlineExceeded)
        callback.open()
        #expect(await settles { !AbandonedWork.ledger.holdsSlots(label: label) })
    }

    @Test(.failureMode("design/01", "every slot of a label is held by abandoned work"))
    func aLabelWedgedByAsyncWorkRefusesNewWork() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let callback = AsyncGate()
        let label = Self.uniqueLabel("wedged.async")
        try await withTestAmbient(clock: clock, events: events) {
            async let attempt: Int = abandoningAsyncAfter(.seconds(1), label: label, limit: 1) { () async throws(Failure) -> Int in
                await callback.wait()
                return 1
            }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(1))
            _ = try? await attempt
            do {
                _ = try await abandoningAsyncAfter(.seconds(1), label: label, limit: 1) { () async throws(Failure) -> Int in 2 }
                Issue.record("expected the wedged label to refuse")
            } catch let error as PolicyError<Failure> {
                #expect(error.rejection?.reason == .abandonmentLimit)
            }
        }
        #expect(events.names.contains("abandoned.wedged"))
        callback.open()
        #expect(await settles { !AbandonedWork.ledger.holdsSlots(label: label) })
    }

    @Test(.failureMode("design/01", "the caller is already cancelled on entry (abandoning)"))
    func anAlreadyCancelledCallerStartsNothing() async throws {
        let ran = SendableBox(false)
        let label = Self.uniqueLabel("cancelled.async")
        let task = Task {
            try? await Task.sleep(for: .seconds(3600))   // returns at once: the task is cancelled
            return try await abandoningAsyncAfter(.seconds(5), label: label) { () async throws(Failure) -> Int in
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
        try await Task.sleep(for: .milliseconds(50))
        #expect(ran.value == false)
    }

    @Test(.failureMode("design/04", "work started in the scope was abandoned"))
    func asyncWorkAbandonedInAScopeIsCounted() async {
        let clock = TestClock()
        let callback = AsyncGate()
        let closed = SendableBox(false)
        let label = Self.uniqueLabel("scope.async")
        await withScope { scope in
            scope.onExit(ifWorkAbandoned: .quarantine) { _ in closed.mutate { $0 = true } }
            async let attempt: Int = abandoningAsyncAfter(.seconds(2), label: label, clock: clock.erased) { () async throws(Failure) -> Int in
                await callback.wait()
                return 1
            }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(2))
            do {
                _ = try await attempt
                Issue.record("expected the work to be abandoned")
            } catch let error as PolicyError<Failure> {
                #expect(error.rejection?.reason == .deadlineExceeded)
            } catch {
                Issue.record(error)
            }
            #expect(scope.abandonedWork == 1)
        }
        #expect(!closed.value, "a resource abandoned async work may still use is not released under it")
        callback.open()
        #expect(await settles { !AbandonedWork.ledger.holdsSlots(label: label) })
    }
}
