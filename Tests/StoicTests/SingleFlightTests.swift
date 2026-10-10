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
}
