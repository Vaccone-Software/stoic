@testable import Stoic
import StoicTesting
import Testing

/// A policy that logs when it is entered and left, and can refuse.
struct Tracer: Policy {
    let name: String
    let log: OrderLog
    var refuses: Rejection?

    func execute<R, Failure: Error>(
        _ operation: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(PolicyError<Failure>) -> R {
        log.append("\(name) in")
        defer { log.append("\(name) out") }
        if let refuses { throw .rejected(refuses) }
        do throws(Failure) {
            return try await operation()
        } catch {
            throw .failed(error)
        }
    }
}

@Suite("Pipeline")
struct PipelineTests {
    @Test func anEmptyPipelineJustRunsTheOperation() async {
        let pipeline = Pipeline([])
        let value = await outcome(of: pipeline) { 5 }
        if case .success(let number) = value { #expect(number == 5) } else { unexpected("expected a value") }
        let failed = await outcome(of: pipeline) { () throws(Boom) -> Int in throw .failed }
        if case .failure(let error) = failed { #expect(error.failure == .failed) } else { unexpected("expected a failure") }
    }

    @Test func stagesRunOutermostFirstAndUnwindInReverse() async {
        let log = OrderLog()
        let pipeline = Pipeline(Tracer(name: "a", log: log), Tracer(name: "b", log: log), Tracer(name: "c", log: log))
        _ = await outcome(of: pipeline) { log.append("operation") }
        #expect(log.values == ["a in", "b in", "c in", "operation", "c out", "b out", "a out"])
    }

    @Test func aRefusalFromAnyDepthArrivesAsOneRejectionAndStopsTheOperation() async {
        for refusingDepth in 0..<3 {
            let log = OrderLog()
            let stages = (0..<3).map { index in
                Tracer(name: "\(index)", log: log, refuses: index == refusingDepth ? Rejection(.bulkheadFull, label: "stage \(index)") : nil)
            }
            let pipeline = Pipeline(stages)
            let result = await outcome(of: pipeline) { () throws(Boom) in log.append("operation") }
            guard case .failure(let error) = result else { return unexpected("expected a rejection") }
            // One level: `.rejected`, never `.failed(.rejected(…))`.
            #expect(error.rejection?.label == "stage \(refusingDepth)")
            #expect(error.failure == nil)
            #expect(!log.values.contains("operation"))
        }
    }

    @Test func theOperationsOwnErrorSurvivesEveryStageUnwrapped() async {
        let log = OrderLog()
        let pipeline = Pipeline(Tracer(name: "a", log: log), Tracer(name: "b", log: log), Tracer(name: "c", log: log))
        let result = await outcome(of: pipeline) { () throws(Boom) -> Void in throw .notFound }
        guard case .failure(let error) = result else { return unexpected("expected a failure") }
        #expect(error.failure == .notFound)
        #expect(error.rejection == nil)
    }

    @Test func aBreakerOutsideABulkheadNeverCountsTheBulkheadsRefusals() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "api", testConfiguration(minimumCalls: 1), clock: clock.erased)
            let bulkhead = Bulkhead(maxConcurrent: 1, label: "api")
            let pipeline = Pipeline(breaker, bulkhead)
            let gate = AsyncGate()
            let holder = Task { await outcome(of: pipeline) { await gate.wait() } }
            await waitUntil { bulkhead.activeCount == 1 }
            for _ in 0..<10 {
                let refusal = await rejection(from: pipeline) { () throws(Boom) in unexpected() }
                #expect(refusal?.reason == .bulkheadFull)
            }
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.calls == 0)
            #expect(events.events(named: "breaker.ignored").count == 10)
            gate.open()
            _ = await holder.value
            #expect(breaker.snapshot.calls == 1)
        }
    }

    @Test func aProbeRefusedByAnInnerPolicyIsNotUsedUp() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "api", testConfiguration(), clock: clock.erased)
            let limiter = RateLimiter(rate: 1, burst: 1, queueLimit: 0, label: "api", clock: clock.erased)
            let pipeline = Pipeline(breaker, limiter)
            await breaker.failUntilOpen()
            #expect(limiter.tryAcquire())                 // drain the bucket
            await clock.advance(by: .milliseconds(30_000))   // the breaker half-opens; the bucket refills one permit
            #expect(limiter.tryAcquire())                 // drain it again
            let refusal = await rejection(from: pipeline) { () throws(Boom) in unexpected() }
            #expect(refusal?.reason == .rateLimited)
            #expect(breaker.state == .halfOpen)           // the probe permit came back
            await clock.advance(by: .seconds(1))
            let result = await outcome(of: pipeline) { 1 }
            if case .success = result {} else { unexpected("the probe should run") }
            #expect(breaker.state == .closed)
        }
    }

    @Test func retryingOutsideABreakerWaitsOutTheBreakersRetryAfter() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "api", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(10))   // 20 s of the open period remain
            let pipeline = Pipeline(
                Retrying(.fixed(.seconds(1)).attempts(3), budget: .unlimited, label: "api"),
                breaker
            )
            let task = Task { await outcome(of: pipeline) { 42 } }
            await clock.waitForSleepers(count: 1)
            // The schedule says one second; the breaker's rejection says twenty.
            #expect(clock.pendingDeadlines.map(\.offset) == [.seconds(30)])
            await clock.advance(by: .seconds(20))
            let result = await task.value
            if case .success(let number) = result { #expect(number == 42) } else { unexpected("expected the retry to get through") }
            #expect(breaker.state == .closed)
            #expect(events.events(named: "retry.attempt_failed").first?.duration("delay") == .seconds(20))
        }
    }

    /// An inner `withTimeout` cancels a hung attempt, and the retry stage sees
    /// a plain cancellation, which it takes for the caller's and stops on.
    /// `Retrying(attemptTimeout:)` knows the attempt timed out, so it retries.
    @Test(.timeLimit(.minutes(1)), .failureMode("design/10", "an attempt under `Retrying(attemptTimeout:)` runs out of time"))
    func retryingBoundsEachAttemptAndRetriesOneThatTimesOut() async {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        await withTestAmbient(clock: clock, events: events) {
            let pipeline = Pipeline(
                Retrying(.fixed(.seconds(1)).attempts(3), budget: .unlimited, attemptTimeout: .seconds(2), label: "api")
            )
            let calls = SendableBox(0)
            let task = Task {
                await outcome(of: pipeline) { () async throws -> Int in
                    calls.mutate { $0 += 1 }
                    try await clock.sleep(for: .seconds(3600))   // hangs until its attempt is cut off
                    return 1
                }
            }
            for attempt in 1...3 {
                await clock.waitForSleepers(count: 2)       // the attempt, and its timeout
                await clock.advance(by: .seconds(2))
                if attempt < 3 {
                    await clock.waitForSleepers(count: 1)   // the backoff
                    await clock.advance(by: .seconds(1))
                }
            }
            let result = await task.value
            if case .failure(let error) = result { #expect(error.failure is CancellationError) } else { unexpected("every attempt timed out") }
            #expect(calls.value == 3, "a timed-out attempt is transient: all three attempts run")
            #expect(events.events(named: "retry.attempt_failed").count == 2)
        }
    }

    @Test func aRetryThatMeetsAnOpenBreakerGetsItsRetryAfterAndEndsWithTheOperationsOwnError() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "api", testConfiguration(minimumCalls: 2), clock: clock.erased)
            let pipeline = Pipeline(
                Retrying(.fixed(.milliseconds(200)).attempts(4), budget: .unlimited, label: "api"),
                breaker
            )
            let calls = SendableBox(0)
            let task = Task {
                await outcome(of: pipeline) { () throws(Boom) -> Int in
                    calls.mutate { $0 += 1 }
                    throw .failed
                }
            }
            // Attempts 1 and 2 fail (t = 0, 200 ms) and open the breaker; attempt 3
            // (t = 400 ms) is rejected; attempt 4 is the half-open probe, after the
            // breaker's own retryAfter, and fails.
            for _ in 0..<3 {
                await clock.waitForSleepers(count: 1)
                await clock.advanceToNextDeadline()
            }
            let result = await task.value
            guard case .failure(let error) = result else { return unexpected("expected a failure") }
            #expect(error.failure == .failed)   // one flat level: the operation's own error
            #expect(calls.value == 3)           // the rejected attempt never ran it
            let delays = events.events(named: "retry.attempt_failed").map { $0.duration("delay") }
            #expect(delays == [.milliseconds(200), .milliseconds(200), .seconds(29) + .milliseconds(800)])
            #expect(breaker.state == .open)
        }
    }

    @Test func theFullHTTPStackRunsOnVirtualTime() async {
        await withBreakerWorld { clock, events in
            struct HTTPError: Error, Retryable, Equatable {
                let status: Int
                var retryDecision: RetryDecision { status >= 500 ? .retry : .stop }
            }
            let breaker = CircuitBreaker(label: "api", testConfiguration(minimumCalls: 10), clock: clock.erased)
            let limiter = RateLimiter(rate: 50, burst: 100, label: "api", clock: clock.erased)
            let bulkhead = Bulkhead(maxConcurrent: 8, queueLimit: 16, label: "api")
            let pipeline = Pipeline(
                Retrying(.fixed(.milliseconds(200)).attempts(4), budget: .unlimited, label: "api"),
                breaker, limiter, bulkhead
            )
            let statuses = SendableBox([503, 503, 200])
            let task = Task {
                await outcome(of: pipeline) { () async throws(HTTPError) -> String in
                    let status = statuses.mutate { $0.removeFirst() }
                    if status != 200 { throw HTTPError(status: status) }
                    return "ok"
                }
            }
            for _ in 0..<2 {
                await clock.waitForSleepers(count: 1)
                await clock.advance(by: .milliseconds(200))
            }
            let result = await task.value
            if case .success(let body) = result { #expect(body == "ok") } else { unexpected("expected the third attempt to succeed") }
            #expect(clock.now.offset == .milliseconds(400))
            #expect(breaker.snapshot.calls == 3)
            #expect(breaker.snapshot.failures == 2)
            #expect(limiter.availablePermits == 99)   // 100, less one per call, refilled between
            #expect(bulkhead.activeCount == 0)
            #expect(events.events(named: "retry.attempt_failed").count == 2)
            #expect(events.events(named: "retry.succeeded").count == 1)
        }
    }

    @Test func aTimeoutAroundAPipelineKeepsItsErrorTypeAndACancelledCallerIsNotRecorded() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "api", testConfiguration(minimumCalls: 1), clock: clock.erased)
            let pipeline = Pipeline(breaker, Bulkhead(maxConcurrent: 4, label: "api"))
            let task = Task { () async -> Result<Int, PolicyError<Boom>> in
                do throws(PolicyError<Boom>) {
                    // withTimeout passes the pipeline's error type through untouched.
                    return .success(try await withTimeout(.seconds(5)) { () async throws(PolicyError<Boom>) -> Int in
                        try await pipeline.execute { () async throws(Boom) -> Int in
                            do { try await clock.sleep(until: .init(offset: .seconds(100)), tolerance: nil) } catch { throw .failed }
                            return 1
                        }
                    })
                } catch {
                    return .failure(error)
                }
            }
            await clock.waitForSleepers(count: 2)
            await clock.advance(by: .seconds(5))
            let result = await task.value
            guard case .failure(let error) = result else { return unexpected("expected the timeout to cut the call short") }
            #expect(error.failure == .failed)
            // The pipeline's caller was cancelled by the timeout: nothing is evidence about the dependency.
            #expect(breaker.snapshot.calls == 0)
            #expect(breaker.state == .closed)
        }
    }

    @Test func anAttemptTimeoutInsideTheOperationIsSeenByTheBreakerAsAFailure() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "api", testConfiguration(minimumCalls: 1), clock: clock.erased)
            let pipeline = Pipeline(breaker)
            let task = Task { () async -> Result<Int, PolicyError<Boom>> in
                await outcome(of: pipeline) { () async throws(Boom) -> Int in
                    try await withTimeout(.seconds(2)) { () async throws(Boom) -> Int in
                        do { try await clock.sleep(until: .init(offset: .seconds(100)), tolerance: nil) } catch { throw .failed }
                        return 1
                    }
                }
            }
            await clock.waitForSleepers(count: 2)
            await clock.advance(by: .seconds(2))
            _ = await task.value
            // The caller was not cancelled; the attempt timed out: a failure, which opened it.
            #expect(breaker.state == .open)
            #expect(events.events(named: "breaker.opened").first?.number("failures") == 1)
        }
    }
}
