@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// A backend's breaker: what it counts, and what an open one does to a call
/// at each urgency (design/22, Breaker).
@Suite("Operation breakers")
struct OperationBreakerTests {
    /// The breaker of `backend` in the running test's registry.
    static func breaker(_ backend: Backend) -> CircuitBreaker? {
        Ambient.current.backends.existing(backend)?.breaker
    }

    /// Opens `operation`'s backend breaker the honest way: twenty failed
    /// attempts (ten interactive calls of two attempts each).
    static func trip(_ operation: Backend.Operation) async {
        for _ in 0..<10 {
            _ = await withUrgency(.interactive) { await performing(operation, Script([.fail(Transient())])) }
        }
    }

    @Test(.failureMode("design/22", "the breaker is open and the call is interactive"))
    func anOpenBreakerFailsAnInteractiveCallAtOnce() async throws {
        let backend = Backend.remote("breaker.interactive")
        let fetch = backend.readOnly("fetch")
        let script = Script([.succeed])
        let run = try await simulated { context in
            await Self.trip(fetch)
            let opened = context.clock.now.offset
            let refused = await withUrgency(.interactive) { await performing(fetch, script) }
            return (refused, opened, context.clock.now.offset)
        }
        let (refused, opened, finished) = run.value
        let error = try #require(refused.error)
        #expect(error.stopName == "circuit_open")
        #expect(error.attempts == 0)
        #expect(error.outcome == .notExecuted)
        #expect(finished == opened)
        #expect(script.count == 0)
    }

    @Test(.failureMode("design/22", "the breaker is open and the call is background"))
    func aBackgroundCallWaitsOutAnOpenBreaker() async throws {
        let backend = Backend.remote("breaker.background")
        let fetch = backend.readOnly("fetch")
        let script = Script([.succeed])
        let run = try await simulated { context in
            await Self.trip(fetch)
            let retryAfter = Self.breaker(backend)!.snapshot.retryAfter!
            let opened = context.clock.now.offset
            let retries = context.events.events(named: "retry.attempt_failed").count
            let result = await withUrgency(.background) { await performing(fetch, script) }
            return (result, retryAfter, opened, context.events.events(named: "retry.attempt_failed").count - retries)
        }
        let (result, retryAfter, opened, retries) = run.value
        #expect(result.success == 1)
        // One attempt, after the open period, jittered up to a tenth later.
        let started = try #require(script.calls.first?.at) - opened
        #expect(started >= retryAfter)
        #expect(started <= retryAfter + retryAfter * 0.1)
        // The waits were no attempts, and no retries paid for with a token.
        #expect(script.count == 1)
        #expect(retries == 0)
    }

    @Test func aBackgroundCallWaitsAtMostThreeTimes() async throws {
        let backend = Backend.remote("breaker.three-waits")
        let fetch = backend.readOnly("fetch")
        let script = Script([.succeed])
        let run = try await simulated { context in
            _ = await performing(fetch, Script([.succeed]))   // creates the state
            Self.breaker(backend)!.forceOpen()
            let start = context.clock.now.offset
            let result = await withUrgency(.background) { await performing(fetch, script) }
            return (result, context.clock.now.offset - start)
        }
        let error = try #require(run.value.0.error)
        #expect(error.stopName == "circuit_open")
        #expect(error.attempts == 0)
        // A forced-open breaker has no retryAfter: each wait is bounded by
        // the half-open timeout (60 s), three times.
        #expect(run.value.1 == .seconds(180))
        #expect(script.count == 0)
    }

    @Test func aWaitThatWouldPassTheDeadlineIsNotTaken() async throws {
        let backend = Backend.remote("breaker.wait-past-deadline")
        let fetch = backend.readOnly("fetch")
        let run = try await simulated { context in
            await Self.trip(fetch)
            let start = context.clock.now.offset
            let result = await withUrgency(.background) {
                await withDeadline(.after(.seconds(5))) { await performing(fetch, Script([.succeed])) }
            }
            return (result, context.clock.now.offset - start)
        }
        #expect(run.value.0.error?.stopName == "circuit_open")
        #expect(run.value.1 == .zero)
    }

    @Test func aCallRefusedByAHalfOpenBreakerWaitsForTheProbesVerdict() async throws {
        let backend = Backend.remote("breaker.half-open")
        let fetch = backend.readOnly("fetch")
        let waiter = Script([.succeed])
        let run = try await simulated { context in
            await Self.trip(fetch)
            let retryAfter = Self.breaker(backend)!.snapshot.retryAfter!
            try? await Ambient.sleep(for: retryAfter)
            return await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    // The probe: slow, then healthy.
                    _ = await withUrgency(.interactive) { await performing(fetch, Script([.after(.seconds(2), .succeed)])) }
                }
                try? await Ambient.sleep(for: .seconds(1))
                let probeOut = context.clock.now.offset
                let result = await withUrgency(.utility) { await performing(fetch, waiter) }
                await group.waitForAll()
                return (result, probeOut)
            }
        }
        #expect(run.value.0.success == 1)
        // It ran the moment the probe closed the breaker.
        #expect(waiter.calls.first?.at == run.value.1 + .seconds(1))
    }

    @Test(.failureMode("design/22", "a remote backend answers 404 (a permanent failure)"))
    func aPermanentFailureIsTheBackendAnswering() async throws {
        let backend = Backend.remote("breaker.permanent")
        let fetch = backend.readOnly("fetch")
        let run = try await simulated { _ in
            for _ in 0..<25 { _ = await performing(fetch, Script([.fail(Permanent())])) }
            return Self.breaker(backend)!.snapshot
        }
        #expect(run.value.state == .closed)
        #expect(run.value.calls == 25)
        #expect(run.value.failures == 0)
    }

    @Test(.failureMode("design/22", "a window full of slow .long calls"))
    func slowLongCallsDoNotOpenTheBreaker() async throws {
        let backend = Backend.remote("breaker.slow-long", capacity: 30)
        let download = backend.readOnly("download", length: .long)
        let run = try await simulated { _ in
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<25 {
                    group.addTask {
                        _ = await withUrgency(.interactive) { await performing(download, Script([.after(.seconds(20), .succeed)])) }
                    }
                }
            }
            return Self.breaker(backend)!.snapshot
        }
        #expect(run.value.state == .closed)
        #expect(run.value.calls == 25)
        #expect(run.value.slowCalls == 0)
    }

    @Test(.failureMode("design/22", "the device is offline (neverReachedBackend)"))
    func aFailureThatNeverReachedTheBackendIsNotRecorded() async throws {
        let backend = Backend.remote("breaker.offline")
        let fetch = backend.readOnly("fetch")
        let run = try await simulated { _ in
            for _ in 0..<15 { _ = await withUrgency(.interactive) { await performing(fetch, Script([.fail(Offline())])) } }
            return Self.breaker(backend)!.snapshot
        }
        #expect(run.value.state == .closed)
        #expect(run.value.calls == 0)
    }

    @Test func anAttemptTimeoutCountsAndTheCallsDeadlineDoesNot() async throws {
        let backend = Backend.remote("breaker.timeouts")
        let fetch = backend.readOnly("fetch")
        let run = try await simulated { _ in
            // Two attempts, each cut by its own 4 s timeout: two failures.
            _ = await withUrgency(.interactive) { await performing(fetch, Script([.hang])) }
            let afterTimeouts = Self.breaker(backend)!.snapshot
            // Cut by the caller's deadline (1 s) before its timeout: nothing.
            _ = await withUrgency(.interactive) {
                await withDeadline(.after(.seconds(1))) { await performing(fetch, Script([.hang])) }
            }
            return (afterTimeouts, Self.breaker(backend)!.snapshot)
        }
        #expect(run.value.0.calls == 2)
        #expect(run.value.0.failures == 2)
        #expect(run.value.1.calls == 2)
    }

    @Test(.failureMode("design/22", "a test opens a breaker"))
    func eachTestSeesItsOwnBreaker() async throws {
        let backend = Backend.remote("breaker.isolated")
        let fetch = backend.readOnly("fetch")
        let first = try await simulated { _ in
            await Self.trip(fetch)
            return Self.breaker(backend)!.state
        }
        #expect(first.value == .open)
        let clock = TestClock()
        let second = await withTestAmbient(clock: clock) {
            (Self.breaker(backend), await performing(fetch, Script([.succeed])), Self.breaker(backend)?.state)
        }
        #expect(second.0 == nil)
        #expect(second.1.success == 1)
        #expect(second.2 == .closed)
    }

    @Test func aSystemBackendsBreakerOpensBriefly() async throws {
        let backend = Backend.system("breaker.system")
        let call = backend.readOnly("call")
        let run = try await simulated { _ in
            for _ in 0..<10 {
                _ = await withUrgency(.interactive) { await performing(call, Script([.fail(Transient())])) }
            }
            return Self.breaker(backend)!.snapshot
        }
        #expect(run.value.state == .open)
        #expect(try #require(run.value.retryAfter) <= .seconds(1))
    }
}
