@testable import Stoic
import StoicTesting
import Testing

@Suite("SingleFlight")
struct SingleFlightTests {
    enum Failure: Error, Equatable { case boom }

    @Test func concurrentCallersShareOneExecution() async throws {
        let flight = SingleFlight<String, Int, Failure>(label: "avatar")
        let runs = SendableBox(0)
        let gate = AsyncGate()
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await flight.run("me") { () async throws(Failure) -> Int in
                        runs.mutate { $0 += 1 }
                        await gate.wait()
                        return 7
                    }
                }
            }
            await eventually { flight.waiterCount(for: "me") == 10 }
            gate.open()
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(values == Array(repeating: 7, count: 10))
        #expect(runs.value == 1)
        #expect(flight.flightCount == 0, "the key is cleared once the flight lands")
    }

    /// The commit hook a cache stores through: a live flight commits once,
    /// before any caller sees the outcome; an abandoned one never does.
    @Test(.timeLimit(.minutes(1))) func onlyALiveFlightCommits() async throws {
        let flight = SingleFlight<String, Int, Failure>(label: "commit")
        let committed = SendableBox<[Int]>([])
        let gate = AsyncGate()
        let (started, finished) = (SendableBox(false), SendableBox(false))
        let abandoned = Task {
            try await flight.run("k", operation: { () async throws(Failure) -> Int in
                started.mutate { $0 = true }
                await gate.wait()   // ignores cancellation
                finished.mutate { $0 = true }
                return 1
            }, commit: { result in committed.mutate { $0.append((try? result.get()) ?? -1) } })
        }
        await waitUntil { started.value }
        abandoned.cancel()
        _ = await abandoned.result
        let value = try await flight.run("k", operation: { () async throws(Failure) -> Int in 2 }, commit: { result in
            committed.mutate { $0.append((try? result.get()) ?? -1) }
        })
        #expect(value == 2)
        #expect(committed.value == [2], "committed before the caller saw it")
        gate.open()
        await waitUntil { finished.value }
        #expect(await holdsThroughout { committed.value == [2] }, "the abandoned flight finished and never committed")
    }

    @Test func everyCallerSeesTheSameFailure() async throws {
        let flight = SingleFlight<Int, Int, Failure>(label: "fail")
        let gate = AsyncGate()
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        _ = try await flight.run(1) { () async throws(Failure) -> Int in
                            await gate.wait()
                            throw .boom
                        }
                        return false
                    } catch let error as PolicyError<Failure> {
                        return error.failure == .boom
                    } catch {
                        return false
                    }
                }
            }
            await eventually { flight.waiterCount(for: 1) == 5 }
            gate.open()
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.allSatisfy { $0 })
    }

    @Test func oneCallerCancellingDoesNotCancelTheOthers() async throws {
        let flight = SingleFlight<Int, String, Never>(label: "refcount")
        let gate = AsyncGate()
        let started = AsyncGate()
        let first = Task { try await flight.run(1) { started.open(); await gate.wait(); return "done" } }
        await started.wait()
        let second = Task { try await flight.run(1) { "never runs" } }
        await eventually { flight.waiterCount(for: 1) == 2 }
        first.cancel()
        do {
            _ = try await first.value
            Issue.record("the cancelled caller should be rejected")
        } catch let error as PolicyError<Never> {
            #expect(error.rejection?.reason == .cancelled)
        }
        gate.open()
        #expect(try await second.value == "done")
    }

    @Test func theLastCallerLeavingCancelsTheFlightAndRetiresTheKey() async throws {
        let flight = SingleFlight<Int, String, any Error>(label: "retire")
        let cancelled = AsyncGate()
        let started = AsyncGate()
        let only = Task {
            try await flight.run(1) {
                started.open()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    cancelled.open()
                    throw error
                }
                return "unreachable"
            }
        }
        await started.wait()
        only.cancel()
        await cancelled.wait()
        _ = try? await only.value
        #expect(flight.flightCount == 0)
        // A newcomer starts a fresh flight instead of joining the dying one.
        let fresh = try await flight.run(1) { "fresh" }
        #expect(fresh == "fresh")
    }

    @Test func aCallersDeadlineBoundsOnlyItsOwnWait() async throws {
        let clock = TestClock()
        let flight = SingleFlight<Int, String, Never>(label: "deadline")
        let gate = AsyncGate()
        let started = AsyncGate()
        let patient = Task { try await flight.run(1) { started.open(); await gate.wait(); return "done" } }
        await started.wait()
        let hasty = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) {
                    try await flight.run(1) { "unused" }
                }
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(1))
        do {
            _ = try await hasty.value
            Issue.record("the hasty caller should be rejected")
        } catch let error as PolicyError<Never> {
            #expect(error.rejection?.reason == .deadlineExceeded)
        }
        gate.open()
        #expect(try await patient.value == "done")
    }

    /// A flight cancelled because its last caller left reads why that
    /// caller left: its deadline passed.
    @Test func aFlightWhoseLastCallerRanOutOfTimeIsCancelledForTheDeadline() async throws {
        let clock = TestClock()
        let flight = SingleFlight<Int, String, any Error>(label: "cause.deadline")
        let observed = SendableBox<CancellationCause?>(nil)
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await withTimeout(.seconds(1)) {
                    try await flight.run(1) {
                        do { try await Task.sleep(for: .seconds(60)) } catch {
                            observed.mutate { $0 = CancellationCause.current }
                            throw error
                        }
                        return "unreachable"
                    }
                }
            }
        }
        await clock.waitForSleepers(count: 2)   // the caller's deadline and the flight's wait
        await clock.advance(by: .seconds(1))
        _ = try? await task.value
        #expect(await eventually { observed.value != nil })
        #expect(observed.value == .deadline)
    }

    /// ...and, cancelled by an enclosing Stoic scope, the cause that scope
    /// recorded, not "the user cancelled".
    @Test func aFlightWhoseLastCallerWasCancelledByAScopeReadsTheScopesCause() async throws {
        let flight = SingleFlight<Int, String, any Error>(label: "cause.scope")
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        _ = try? await withTaskScope { scope in
            scope.fork(label: "breaks") {
                await started.wait()
                throw Failure.boom
            }
            _ = try await flight.run(1) {
                started.open()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    observed.mutate { $0 = CancellationCause.current }
                    throw error
                }
                return "unreachable"
            }
        }
        #expect(await eventually { observed.value != nil })
        #expect(observed.value == .siblingFailed)
    }

    /// With no Stoic scope behind the cancellation, the flight reads
    /// `.userRequested`.
    @Test func aFlightWhoseLastCallerWasCancelledReadsUserRequested() async throws {
        let flight = SingleFlight<Int, String, any Error>(label: "cause.user")
        let observed = SendableBox<CancellationCause?>(nil)
        let started = AsyncGate()
        let task = Task {
            try await flight.run(1) {
                started.open()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    observed.mutate { $0 = CancellationCause.current }
                    throw error
                }
                return "unreachable"
            }
        }
        await started.wait()
        task.cancel()
        _ = try? await task.value
        #expect(await eventually { observed.value != nil })
        #expect(observed.value == .userRequested)
    }
}
