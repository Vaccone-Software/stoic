@testable import Stoic
import StoicTesting
import Testing

enum Boom: Error, Equatable { case failed, notFound }
struct Bug: Defect {}

/// A breaker configuration for tests: no jitter, a fixed starting point,
/// everything else as the test says.
func testConfiguration(
    window: CircuitBreaker.Window = .calls(100),
    minimumCalls: Int = 5,
    failureRate: Double = 0.5,
    slowAfter: Duration = .seconds(10),
    slowRate: Double = 1,
    open: CircuitBreaker.OpenDuration = .exponential(initial: .seconds(30), factor: 2, maximum: .seconds(300), jitter: 0),
    probes: Int = 1,
    probeTimeout: Duration = .seconds(60),
    recordWhen: @escaping @Sendable (any Error) -> Bool = CircuitBreaker.countsByDefault
) -> CircuitBreaker.Configuration {
    CircuitBreaker.Configuration(
        window: window, minimumCalls: minimumCalls, failureRateThreshold: failureRate,
        slowCallDuration: slowAfter, slowCallRateThreshold: slowRate, openDuration: open,
        halfOpenProbes: probes, halfOpenTimeout: probeTimeout, recordWhen: recordWhen
    )
}

/// Runs `body` on a fresh virtual clock with recorded events.
func withBreakerWorld(
    seed: UInt64 = 0,
    _ body: nonisolated(nonsending) (TestClock, RecordingInstrumentation) async -> Void
) async {
    let clock = TestClock()
    let events = RecordingInstrumentation()
    await withTestAmbient(clock: clock, seed: seed, events: events) {
        await body(clock, events)
    }
}

extension CircuitBreaker {
    /// A call that succeeds.
    @discardableResult
    func succeed() async -> Result<Int, PolicyError<Never>> {
        await outcome(of: self) { 1 }
    }

    /// A call that fails.
    @discardableResult
    func fail(_ error: Boom = .failed) async -> Result<Int, PolicyError<Boom>> {
        await outcome(of: self) { () throws(Boom) -> Int in throw error }
    }

    /// Fails until the breaker opens (or `calls` is exhausted).
    func failUntilOpen(calls: Int = 100) async {
        for _ in 0..<calls where state == .closed { await fail() }
    }
}

@Suite("CircuitBreaker")
struct CircuitBreakerTests {
    // MARK: - Judging

    @Test(.failureMode("design/10", "a breaker has fewer than minimumCalls calls in its window")) func staysClosedUntilItHasSeenMinimumCalls() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "min", testConfiguration(minimumCalls: 5), clock: clock.erased)
            for _ in 0..<4 { await breaker.fail() }
            #expect(breaker.state == .closed)   // 100% failed, but only four calls
            await breaker.fail()
            #expect(breaker.state == .open)
        }
    }

    @Test(.failureMode("design/10", "the failure rate reaches the threshold with enough calls")) func opensAtTheFailureRateExactlyAndNotBelow() async {
        await withBreakerWorld { clock, _ in
            // 4 of 10 is 40%: below. The tenth call makes 5 of 10 = 50%: at.
            let breaker = CircuitBreaker(label: "rate", testConfiguration(minimumCalls: 10), clock: clock.erased)
            for _ in 0..<4 { await breaker.fail() }
            for _ in 0..<5 { await breaker.succeed() }
            #expect(breaker.state == .closed)
            await breaker.succeed()   // 4/10
            #expect(breaker.state == .closed)
            await breaker.fail()      // 5/11: 45%
            #expect(breaker.state == .closed)
            await breaker.fail()      // 6/12: 50%
            #expect(breaker.state == .open)
        }
    }

    @Test func aRateOfExactlyOneTenthIsComparedWithoutFloatingPointError() async {
        await withBreakerWorld { clock, _ in
            let config = testConfiguration(minimumCalls: 10, failureRate: 0.1)
            let breaker = CircuitBreaker(label: "tenth", config, clock: clock.erased)
            await breaker.fail()
            for _ in 0..<9 { await breaker.succeed() }
            #expect(breaker.state == .open)   // 1 of 10 is exactly 10%

            let other = CircuitBreaker(label: "eleventh", config, clock: clock.erased)
            for _ in 0..<10 { await other.succeed() }
            await other.fail()   // 1 of 11
            #expect(other.state == .closed)
        }
    }

    @Test(.failureMode("design/10", "the slow-call rate reaches the threshold with enough calls")) func slowCallsOpenTheBreakerEvenWhenTheySucceed() async {
        await withBreakerWorld { clock, events in
            let config = testConfiguration(minimumCalls: 4, slowAfter: .seconds(1), slowRate: 0.5)
            let breaker = CircuitBreaker(label: "slow", config, clock: clock.erased)
            for _ in 0..<2 { await breaker.succeed() }
            // Two slow calls of four is half: at the threshold.
            _ = await outcome(of: breaker) { await clock.advance(by: .seconds(2)) }
            #expect(breaker.state == .closed)
            _ = await outcome(of: breaker) { await clock.advance(by: .seconds(2)) }
            #expect(breaker.state == .open)
            let opened = events.events(named: "breaker.opened")
            #expect(opened.first?.text("trigger") == "slow_calls")
            #expect(opened.first?.number("slow_calls") == 2)
            #expect(opened.first?.number("failures") == 0)
        }
    }

    @Test func aCallExactlyAtTheSlowThresholdIsNotSlow() async {
        await withBreakerWorld { clock, _ in
            let config = testConfiguration(minimumCalls: 1, slowAfter: .seconds(1), slowRate: 0.5)
            let breaker = CircuitBreaker(label: "boundary", config, clock: clock.erased)
            _ = await outcome(of: breaker) { await clock.advance(by: .seconds(1)) }
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.slowCalls == 0)
            _ = await outcome(of: breaker) { await clock.advance(by: .seconds(1) + .milliseconds(1)) }
            #expect(breaker.state == .open)
        }
    }

    // MARK: - Open

    @Test(.failureMode("design/10", "a call arrives while open")) func anOpenBreakerRejectsWithTheTimeLeftAndDoesNotRunTheOperation() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "open", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(10))
            let ran = SendableBox(false)
            let result = await outcome(of: breaker) { ran.mutate { $0 = true } }
            guard case .failure(let error) = result else { return unexpected("expected a rejection") }
            #expect(error.rejection?.reason == .circuitOpen)
            #expect(error.rejection?.retryAfter == .seconds(20))
            #expect(error.rejection?.label == "open")
            #expect(!ran.value)
            let rejected = events.events(named: "breaker.rejected")
            #expect(rejected.last?.text("state") == "open")
            #expect(rejected.last?.duration("retry_after") == .seconds(20))
            #expect(breaker.snapshot.retryAfter == .seconds(20))
        }
    }

    @Test func theOpenEventCarriesWhyAndHowLong() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "events", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            let opened = events.events(named: "breaker.opened")
            #expect(opened.count == 1)
            #expect(opened[0].label == "events")
            #expect(opened[0].level == .warning)
            #expect(opened[0].text("trigger") == "failure_rate")
            #expect(opened[0].number("calls") == 5)
            #expect(opened[0].number("failures") == 5)
            #expect(opened[0].duration("open_for") == .seconds(30))
            #expect(opened[0].number("trips") == 1)
        }
    }

    // MARK: - Half-open

    @Test(.failureMode("design/10", "the open duration has elapsed")) func theBreakerMovesToHalfOpenWhenTheOpenPeriodEnds() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "half", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(29))
            #expect(breaker.state == .open)
            await clock.advance(by: .seconds(1))
            #expect(breaker.state == .halfOpen)
            #expect(events.events(named: "breaker.half_open").count == 1)
            #expect(events.events(named: "breaker.half_open")[0].number("probes") == 1)
        }
    }

    @Test(.failureMode("design/10", "more calls arrive than there are probe permits")) func halfOpenAdmitsExactlyTheProbePermitsConcurrentlyAndRejectsTheRest() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "probes", testConfiguration(probes: 3), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            let gate = AsyncGate()
            let counts = SendableBox((started: 0, rejected: 0, peak: 0, succeeded: 0))
            let tasks = (0..<6).map { _ in
                Task {
                    let result = await outcome(of: breaker) { () async -> Void in
                        counts.mutate { $0.started += 1; $0.peak = max($0.peak, $0.started) }
                        await gate.wait()
                    }
                    switch result {
                    case .success: counts.mutate { $0.succeeded += 1 }
                    case .failure(let error):
                        #expect(error.rejection?.reason == .circuitOpen)
                        #expect(error.rejection?.retryAfter == nil)
                        counts.mutate { $0.rejected += 1 }
                    }
                }
            }
            await waitUntil { counts.value.started == 3 && counts.value.rejected == 3 }
            #expect(counts.value.peak == 3)
            #expect(breaker.state == .halfOpen)
            gate.open()
            for task in tasks { await task.value }
            #expect(counts.value.succeeded == 3)
            #expect(counts.value.started == 3)
            #expect(breaker.state == .closed)
            #expect(events.events(named: "breaker.closed").last?.text("reason") == "probes_succeeded")
        }
    }

    @Test func probePermitsAreTotalForTheEpisodeNotPerConcurrency() async {
        await withBreakerWorld { clock, _ in
            // Two probes, run one after the other: after the first succeeds
            // there is still exactly one permit left, not two.
            let breaker = CircuitBreaker(label: "total", testConfiguration(probes: 2), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            await breaker.succeed()
            #expect(breaker.state == .halfOpen)
            let gate = AsyncGate()
            let started = SendableBox(0)
            let second = Task { await outcome(of: breaker) { started.mutate { $0 += 1 }; await gate.wait() } }
            await waitUntil { started.value == 1 }
            let third = await breaker.succeed()
            if case .failure(let error) = third { #expect(error.rejection?.reason == .circuitOpen) } else { unexpected("only one permit remained") }
            gate.open()
            _ = await second.value
            #expect(breaker.state == .closed)
        }
    }

    @Test(.failureMode("design/10", "every probe succeeds")) func aSuccessfulProbeClosesTheBreakerWithAnEmptyWindow() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "close", testConfiguration(minimumCalls: 3), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            await breaker.succeed()
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.calls == 0)
            // A closed breaker needs its minimum again before it judges.
            await breaker.fail()
            await breaker.fail()
            #expect(breaker.state == .closed)
            await breaker.fail()
            #expect(breaker.state == .open)
            #expect(events.events(named: "breaker.closed").count == 1)
        }
    }

    @Test(.failureMode("design/10", "a probe fails")) func aFailedProbeReopensForLongerEachTime() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "growth", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            var expected: [Duration] = [.seconds(30)]
            for open in [Duration.seconds(30), .seconds(60), .seconds(120), .seconds(240), .seconds(300)] {
                await clock.advance(by: open)
                #expect(breaker.state == .halfOpen)
                await breaker.fail()
                #expect(breaker.state == .open)
                expected.append(min(open * 2, .seconds(300)))
                #expect(breaker.snapshot.retryAfter == expected.last)
            }
            let opened = events.events(named: "breaker.opened")
            #expect(opened.map { $0.duration("open_for") } == expected)
            #expect(opened.dropFirst().allSatisfy { $0.text("trigger") == "probe_failed" })
            #expect(opened.map { $0.number("trips") } == Array(1...6))
        }
    }

    @Test func aSlowProbeCountsAsAFailedOne() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "slow-probe", testConfiguration(slowAfter: .seconds(1)), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            _ = await outcome(of: breaker) { await clock.advance(by: .seconds(2)) }
            #expect(breaker.state == .open)
            #expect(events.events(named: "breaker.opened").last?.text("trigger") == "probe_slow")
        }
    }

    @Test(.failureMode("design/10", "a dependency stays healthy for resetAfter after closing")) func growthStartsOverOnlyAfterTheBreakerHasStayedClosedLongEnough() async {
        await withBreakerWorld { clock, _ in
            let open = CircuitBreaker.OpenDuration.exponential(
                initial: .seconds(30), factor: 2, maximum: .seconds(300), jitter: 0, resetAfter: .seconds(100)
            )
            let breaker = CircuitBreaker(label: "reset-after", testConfiguration(open: open), clock: clock.erased)
            await breaker.failUntilOpen()                       // trip 0: 30 s
            await clock.advance(by: .seconds(30))
            await breaker.succeed()                             // closes
            await clock.advance(by: .seconds(99))               // closed for 99 s: not yet healthy enough
            await breaker.failUntilOpen()
            #expect(breaker.snapshot.retryAfter == .seconds(60))   // trip 1
            await clock.advance(by: .seconds(60))
            await breaker.succeed()
            await clock.advance(by: .seconds(100))              // closed for 100 s: a fresh start
            await breaker.failUntilOpen()
            #expect(breaker.snapshot.retryAfter == .seconds(30))
            #expect(breaker.snapshot.trips == 1)
        }
    }

    @Test func jitterOnlyShortensTheOpenPeriodAndFollowsTheSeed() async {
        var seen: [Duration] = []
        for seed in [UInt64(1), 1, 2] {
            await withBreakerWorld(seed: seed) { clock, _ in
                let open = CircuitBreaker.OpenDuration.exponential(initial: .seconds(30), factor: 2, maximum: .seconds(300), jitter: 0.5)
                let breaker = CircuitBreaker(label: "jitter", testConfiguration(open: open), clock: clock.erased)
                await breaker.failUntilOpen()
                let period = breaker.snapshot.retryAfter ?? .zero
                #expect(period >= .seconds(15) && period <= .seconds(30))
                seen.append(period)
            }
        }
        #expect(seen[0] == seen[1])
        #expect(seen[0] != seen[2])
    }

    @Test(.failureMode("design/10", "a probe is still running after halfOpenTimeout")) func aProbeThatNeverFinishesIsGivenUpOn() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "wedge", testConfiguration(probeTimeout: .seconds(60)), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            let gate = AsyncGate()
            let started = SendableBox(0)
            let probe = Task { await outcome(of: breaker) { started.mutate { $0 += 1 }; await gate.wait() } }
            await waitUntil { started.value == 1 }
            await clock.advance(by: .seconds(59))
            #expect(breaker.state == .halfOpen)
            await clock.advance(by: .seconds(1))
            #expect(breaker.state == .open)
            #expect(events.events(named: "breaker.opened").last?.text("trigger") == "probe_timeout")
            gate.open()
            _ = await probe.value   // the late probe ends as a stale call
            #expect(breaker.state == .open)
            #expect(events.events(named: "breaker.ignored").last?.text("reason") == "stale")
        }
    }

    // MARK: - What counts

    @Test(.failureMode("design/10", "the caller is cancelled while the operation runs")) func aCancelledCallerIsNeverRecordedWhatEverTheOperationThrew() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "cancel", testConfiguration(minimumCalls: 1), clock: clock.erased)
            for _ in 0..<10 {
                let gate = AsyncGate()
                let task = Task { await outcome(of: breaker) { () async throws(Boom) -> Void in await gate.wait(); throw .failed } }
                await waitUntil { gate.waiterCount == 1 }
                task.cancel()
                gate.open()
                _ = await task.value
            }
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.calls == 0)
            #expect(events.events(named: "breaker.ignored").allSatisfy { $0.text("reason") == "cancelled" })
            #expect(events.events(named: "breaker.ignored").count == 10)
        }
    }

    @Test(.failureMode("design/10", "the caller is cancelled while the operation runs")) func aCancelledProbeReturnsItsPermit() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "cancel-probe", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            let gate = AsyncGate()
            let task = Task { await outcome(of: breaker) { () async throws(Boom) -> Void in await gate.wait(); throw .failed } }
            await waitUntil { gate.waiterCount == 1 }
            task.cancel()
            gate.open()
            _ = await task.value
            #expect(breaker.state == .halfOpen)   // not re-opened: the cancellation said nothing
            await breaker.succeed()               // the permit is back
            #expect(breaker.state == .closed)
        }
    }

    @Test(.failureMode("design/10", "a deadline cancels the call while the operation runs"))
    func aCallCutShortByADeadlineIsASlowFailure() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "deadline", testConfiguration(minimumCalls: 1), clock: clock.erased)
            let task = Task {
                await withDeadline(.after(.seconds(2))) { () async -> Result<Int, PolicyError<Boom>> in
                    await outcome(of: breaker) { () async throws(Boom) -> Int in
                        do { try await clock.sleep(for: .seconds(100)) } catch { throw .failed }
                        return 1
                    }
                }
            }
            await clock.waitForSleepers(count: 2)
            await clock.advance(by: .seconds(2))
            _ = await task.value
            #expect(breaker.state == .open)
            let opened = events.events(named: "breaker.opened").first
            #expect(opened?.number("failures") == 1)
            #expect(opened?.number("slow_calls") == 1)
            #expect(events.events(named: "breaker.recorded").first?.text("reason") == "timed_out")
        }
    }

    @Test func aProbeCutShortByADeadlineReopensInsteadOfReturningItsPermit() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "probe-deadline", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            let task = Task {
                await withDeadline(.after(.seconds(2))) { () async -> Result<Int, PolicyError<Boom>> in
                    await outcome(of: breaker) { () async throws(Boom) -> Int in
                        do { try await clock.sleep(for: .seconds(100)) } catch { throw .failed }
                        return 1
                    }
                }
            }
            await clock.waitForSleepers(count: 2)
            await clock.advance(by: .seconds(2))
            _ = await task.value
            // Re-opened at once, not after halfOpenTimeout: no next caller
            // is handed the permit to hang on.
            #expect(breaker.state == .open)
            #expect(events.events(named: "breaker.opened").last?.text("trigger") == "probe_failed")
        }
    }

    @Test func aSuccessThatFinishesDespiteCancellationStillCounts() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "late-success", testConfiguration(), clock: clock.erased)
            let gate = AsyncGate()
            let task = Task { await outcome(of: breaker) { await gate.wait() } }
            await waitUntil { gate.waiterCount == 1 }
            task.cancel()
            gate.open()
            _ = await task.value
            #expect(breaker.snapshot.calls == 1)
        }
    }

    @Test(.failureMode("design/10", "the operation throws a Defect")) func aDefectIsRethrownReportedLoudlyAndNeverRecorded() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "defect", testConfiguration(minimumCalls: 1), clock: clock.erased)
            let result = await outcome(of: breaker) { () throws(Bug) -> Void in throw Bug() }
            guard case .failure(let error) = result else { return unexpected("expected a failure") }
            #expect(error.failure != nil)
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.calls == 0)
            let defects = events.events(named: "breaker.defect")
            #expect(defects.count == 1)
            #expect(defects[0].level == .error)
        }
    }

    @Test func aDefectInsideAPipelineErrorIsStillADefect() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "wrapped-defect", testConfiguration(minimumCalls: 1), clock: clock.erased)
            _ = await outcome(of: breaker) { () throws(PolicyError<Bug>) -> Void in throw .failed(Bug()) }
            #expect(breaker.snapshot.calls == 0)
        }
    }

    @Test func aDefectingProbeReturnsItsPermit() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "defect-probe", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            _ = await outcome(of: breaker) { () throws(Bug) -> Void in throw Bug() }
            #expect(breaker.state == .halfOpen)
            await breaker.succeed()
            #expect(breaker.state == .closed)
        }
    }

    @Test(.failureMode("design/10", "an inner policy rejects (bulkhead full, limiter, budget)")) func anInnerPoliciesRefusalIsNotEvidenceAboutTheDependency() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "inner", testConfiguration(minimumCalls: 1), clock: clock.erased)
            for _ in 0..<5 {
                _ = await outcome(of: breaker) { () throws(PolicyError<Boom>) -> Void in
                    throw .rejected(Rejection(.bulkheadFull, label: "inner-bulkhead"))
                }
            }
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.calls == 0)
            #expect(events.events(named: "breaker.ignored").allSatisfy { $0.text("reason") == "rejection" })
        }
    }

    @Test(.failureMode("design/10", "an inner policy's refusal arrives wrapped by `withContext`"))
    func anInnerRefusalWrappedInContextIsStillARefusal() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "context", testConfiguration(minimumCalls: 1), clock: clock.erased)
            for _ in 0..<5 {
                _ = await outcome(of: breaker) { () async throws -> Int in
                    try withContext("loading the profile") { () throws -> Int in
                        throw PolicyError<Boom>.rejected(Rejection(.bulkheadFull, label: "inner-bulkhead"))
                    }
                }
            }
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.calls == 0)
            #expect(events.events(named: "breaker.ignored").count == 5)
            #expect(events.events(named: "breaker.ignored").allSatisfy { $0.text("reason") == "rejection" })
        }
    }

    @Test func recordWhenSeesThroughReportsAndConcurrentFailures() async {
        await withBreakerWorld { clock, _ in
            let seen = SendableBox<[String]>([])
            let config = testConfiguration(minimumCalls: 10, recordWhen: { error in
                seen.mutate { $0.append(String(describing: type(of: error))) }
                return true
            })
            let breaker = CircuitBreaker(label: "unwrap", config, clock: clock.erased)
            _ = await outcome(of: breaker) { () async throws -> Int in
                try withContext("syncing") { () throws -> Int in throw Boom.failed }
            }
            _ = await outcome(of: breaker) { () throws(ConcurrentFailure<Boom>) -> Int in
                throw ConcurrentFailure([Boom.notFound, Boom.failed])
            }
            #expect(seen.value == ["Boom", "Boom"])
        }
    }

    @Test func aClassifierCanOptIntoCountingARejection() async {
        await withBreakerWorld { clock, _ in
            let config = testConfiguration(minimumCalls: 2, recordWhen: { error in
                CircuitBreaker.countsByDefault(error) || (error as? Rejection)?.reason == .deadlineExceeded
            })
            let breaker = CircuitBreaker(label: "opt-in", config, clock: clock.erased)
            for _ in 0..<2 {
                _ = await outcome(of: breaker) { () throws(PolicyError<Boom>) -> Void in
                    throw .rejected(Rejection(.deadlineExceeded))
                }
            }
            #expect(breaker.state == .open)
        }
    }

    @Test(.failureMode("design/10", "the operation throws CancellationError and the caller is not cancelled")) func aCancellationErrorFromInsideWhileTheCallerIsLiveIsAFailure() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "inner-timeout", testConfiguration(minimumCalls: 2), clock: clock.erased)
            for _ in 0..<2 {
                _ = await outcome(of: breaker) { () throws(CancellationError) -> Void in throw CancellationError() }
            }
            #expect(breaker.state == .open)
        }
    }

    @Test(.failureMode("design/10", "recordWhen returns false for an error")) func anErrorTheClassifierExcusesIsASuccess() async {
        await withBreakerWorld { clock, _ in
            let config = testConfiguration(minimumCalls: 2, recordWhen: { ($0 as? Boom) != .notFound })
            let breaker = CircuitBreaker(label: "excused", config, clock: clock.erased)
            for _ in 0..<10 { await breaker.fail(.notFound) }
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.calls == 10)
            #expect(breaker.snapshot.failures == 0)
            // And a probe that is answered with one closes the breaker.
            let strict = CircuitBreaker(label: "excused-probe", config, clock: clock.erased)
            await strict.failUntilOpen()
            await clock.advance(by: .seconds(30))
            let result = await strict.fail(.notFound)
            if case .failure(let error) = result { #expect(error.failure == .notFound) } else { unexpected("the error must still propagate") }
            #expect(strict.state == .closed)
        }
    }

    @Test(.failureMode("design/10", "a call finishes after the breaker changed state")) func aCallThatFinishesAfterTheBreakerMovedOnIsIgnoredAsStale() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "stale", testConfiguration(minimumCalls: 3), clock: clock.erased)
            let gate = AsyncGate()
            let slow = Task { await outcome(of: breaker) { () async throws(Boom) -> Void in await gate.wait(); throw .failed } }
            await waitUntil { gate.waiterCount == 1 }
            await breaker.failUntilOpen()             // trips while the slow call is in flight
            await clock.advance(by: .seconds(30))
            await breaker.succeed()                   // closes: a new generation
            gate.open()
            _ = await slow.value                      // fails, but belongs to the old one
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.calls == 0)
            #expect(events.events(named: "breaker.ignored").last?.text("reason") == "stale")
        }
    }

    @Test(.failureMode("design/10", "the task is cancelled, or the deadline has passed, before admission")) func aCancelledOrLateTaskIsRefusedBeforeUsingAProbe() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "pre", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            let gate = AsyncGate()
            let cancelled = Task {
                await gate.wait()
                return await rejection(from: breaker) { unexpected() }
            }
            cancelled.cancel()
            gate.open()
            #expect(await cancelled.value?.reason == .cancelled)

            let late = Deadline.after(.seconds(1))
            await clock.advance(by: .seconds(2))
            await Deadline.$stored.withValue(late) {
                #expect(await rejection(from: breaker) { unexpected() }?.reason == .deadlineExceeded)
            }
            // Neither used the probe permit.
            #expect(breaker.state == .halfOpen)
            await breaker.succeed()
            #expect(breaker.state == .closed)
        }
    }

    // MARK: - Windows

    @Test func aTimeWindowForgetsOldFailuresAndACountWindowDoesNot() async {
        await withBreakerWorld { clock, _ in
            let timed = CircuitBreaker(label: "timed", testConfiguration(window: .time(.seconds(60)), minimumCalls: 10), clock: clock.erased)
            let counted = CircuitBreaker(label: "counted", testConfiguration(window: .calls(50), minimumCalls: 10), clock: clock.erased)
            for _ in 0..<9 { await timed.fail(); await counted.fail() }
            await clock.advance(by: .seconds(3600))   // an hour of quiet
            await timed.fail()
            await counted.fail()
            #expect(timed.state == .closed)    // the nine are long forgotten
            #expect(counted.state == .open)    // they are still the last calls
        }
    }

    @Test func aTimeWindowCountsWhatIsInsideItAndRollsOldBucketsOut() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "roll", testConfiguration(window: .time(.seconds(10)), minimumCalls: 100), clock: clock.erased)
            await breaker.fail()
            await clock.advance(by: .seconds(5))
            await breaker.succeed()
            #expect(breaker.snapshot.calls == 2)
            await clock.advance(by: .seconds(5))      // the first bucket is now out
            #expect(breaker.snapshot.calls == 1)
            await clock.advance(by: .seconds(5))
            #expect(breaker.snapshot.calls == 0)
        }
    }

    @Test func aCountWindowKeepsExactlyTheLastNCalls() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "count", testConfiguration(window: .calls(4), minimumCalls: 4, failureRate: 0.75), clock: clock.erased)
            for _ in 0..<3 { await breaker.fail() }     // 3 of 3
            await breaker.succeed()                     // 3 of 4: opens
            #expect(breaker.state == .open)
            breaker.reset()
            await breaker.succeed(); await breaker.succeed()
            await breaker.fail(); await breaker.fail()  // 2 of 4
            await breaker.fail()                        // evicts a success: 3 of 4
            #expect(breaker.state == .open)
        }
    }

    // MARK: - Manual control

    @Test(.failureMode("design/10", "forceOpen()")) func forcedOpenRejectsWithoutAnEndAndNeverProbes() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "forced", testConfiguration(), clock: clock.erased)
            breaker.forceOpen()
            #expect(breaker.state == .open)
            await clock.advance(by: .seconds(100_000))
            #expect(breaker.state == .open)
            let refusal = await rejection(from: breaker) { unexpected() }
            #expect(refusal?.reason == .circuitOpen)
            #expect(refusal?.retryAfter == nil)
            #expect(events.events(named: "breaker.opened").last?.text("trigger") == "forced")
            breaker.forceOpen()   // again: no second event
            #expect(events.events(named: "breaker.opened").count == 1)
        }
    }

    @Test(.failureMode("design/10", "forceClosed() or reset()")) func forceClosedClosesAtOnceAndNormalJudgingResumes() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "force-closed", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            breaker.forceClosed()
            #expect(breaker.state == .closed)
            #expect(events.events(named: "breaker.closed").last?.text("reason") == "forced")
            #expect(breaker.snapshot.calls == 0)
            await breaker.failUntilOpen()   // not a latch
            #expect(breaker.state == .open)
        }
    }

    @Test(.failureMode("design/10", "forceClosed() or reset()")) func resetForgetsTheTripCountToo() async {
        await withBreakerWorld { clock, events in
            let breaker = CircuitBreaker(label: "reset", testConfiguration(), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            await breaker.fail()   // second trip: 60 s
            #expect(breaker.snapshot.retryAfter == .seconds(60))
            breaker.reset()
            #expect(breaker.state == .closed)
            #expect(breaker.snapshot.trips == 0)
            await breaker.failUntilOpen()
            #expect(breaker.snapshot.retryAfter == .seconds(30))
            #expect(events.events(named: "breaker.reset").count == 1)
        }
    }

    @Test func forcingStateLeavesCallsInFlightStale() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "force-stale", testConfiguration(minimumCalls: 1), clock: clock.erased)
            let gate = AsyncGate()
            let inFlight = Task { await outcome(of: breaker) { () async throws(Boom) -> Void in await gate.wait(); throw .failed } }
            await waitUntil { gate.waiterCount == 1 }
            breaker.forceOpen()
            breaker.forceClosed()
            gate.open()
            _ = await inFlight.value
            #expect(breaker.state == .closed)
        }
    }

    // MARK: - stateChanges

    @Test func stateChangesReportsEveryTransitionInOrder() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "stream", testConfiguration(), clock: clock.erased)
            var iterator = breaker.stateChanges.makeAsyncIterator()
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            await breaker.succeed()   // half-open, then closed
            breaker.forceOpen()
            var seen: [CircuitBreaker.State] = []
            for _ in 0..<4 { if let state = await iterator.next() { seen.append(state) } }
            #expect(seen == [.open, .halfOpen, .closed, .open])
        }
    }

    @Test(.failureMode("design/10", "a stateChanges consumer falls behind")) func eachSubscriberGetsItsOwnStreamAndTheBreakerDoesNotWaitForSlowOnes() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "buffer", testConfiguration(), clock: clock.erased)
            var slow = breaker.stateChanges.makeAsyncIterator()
            var fast = breaker.stateChanges.makeAsyncIterator()
            var fastSeen: [CircuitBreaker.State] = []
            for round in 0..<40 {
                breaker.forceOpen()
                if let state = await fast.next() { fastSeen.append(state) }
                breaker.forceClosed()
                if let state = await fast.next() { fastSeen.append(state) }
                _ = round
            }
            #expect(fastSeen.count == 80)
            // The slow reader asks only now: it has the newest sixteen, ending where the breaker is.
            var slowSeen: [CircuitBreaker.State] = []
            for _ in 0..<16 { if let state = await slow.next() { slowSeen.append(state) } }
            #expect(slowSeen.count == 16)
            #expect(slowSeen.last == .closed)
            #expect(slowSeen == (0..<8).flatMap { _ in [CircuitBreaker.State.open, .closed] })
        }
    }

    @Test func streamsThatAreCancelledWhileTransitionsHappenCauseNoHarm() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "stream-cancel", testConfiguration(), clock: clock.erased)
            var consumers: [Task<Int, Never>] = []
            for _ in 0..<8 {
                consumers.append(Task {
                    var count = 0
                    for await _ in breaker.stateChanges {
                        count += 1
                        if count >= 1000 { break }
                    }
                    return count
                })
            }
            let toggler = Task {
                for _ in 0..<300 {
                    breaker.forceOpen()
                    breaker.forceClosed()
                    await Task.yield()
                }
            }
            for (index, consumer) in consumers.enumerated() where index.isMultiple(of: 2) {
                await Task.yield()
                consumer.cancel()
            }
            await toggler.value
            #expect(breaker.state == .closed)
            for consumer in consumers { consumer.cancel() }
            for consumer in consumers { _ = await consumer.value }
            await breaker.succeed()
        }
    }

    // MARK: - Concurrency

    @Test func manyConcurrentCallersAreAllRecordedExactlyOnce() async {
        await withBreakerWorld { clock, _ in
            let config = testConfiguration(window: .calls(1000), minimumCalls: 1000, failureRate: 1)
            let breaker = CircuitBreaker(label: "concurrent", config, clock: clock.erased)
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<400 {
                    group.addTask {
                        if index.isMultiple(of: 4) { await breaker.fail() } else { await breaker.succeed() }
                    }
                }
            }
            let snapshot = breaker.snapshot
            #expect(snapshot.calls == 400)
            #expect(snapshot.failures == 100)
            #expect(breaker.state == .closed)
        }
    }

    @Test func halfOpenNeverRunsMoreProbesThanItHasPermitsUnderContention() async {
        await withBreakerWorld { clock, _ in
            let breaker = CircuitBreaker(label: "contention", testConfiguration(probes: 3), clock: clock.erased)
            await breaker.failUntilOpen()
            await clock.advance(by: .seconds(30))
            let gauge = SendableBox((current: 0, peak: 0, ran: 0))
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<200 {
                    group.addTask {
                        _ = await outcome(of: breaker) { () async throws(Boom) -> Void in
                            gauge.mutate { $0.current += 1; $0.peak = max($0.peak, $0.current); $0.ran += 1 }
                            await Task.yield()
                            gauge.mutate { $0.current -= 1 }
                            throw .failed   // the first failure re-opens it
                        }
                    }
                }
            }
            #expect(gauge.value.peak <= 3)
            #expect(gauge.value.ran >= 1 && gauge.value.ran <= 3)
            #expect(breaker.state == .open)
        }
    }

    // MARK: - Configuration

    @Test func theDefaultsAreTheDocumentedOnes() {
        let config = CircuitBreaker.Configuration()
        #expect(config.window == .time(.seconds(60)))
        #expect(config.minimumCalls == 10)
        #expect(config.failureRateThreshold == 0.5)
        #expect(config.slowCallDuration == .seconds(10))
        #expect(config.slowCallRateThreshold == 1)
        #expect(config.openDuration == CircuitBreaker.OpenDuration.exponential(initial: .seconds(30), factor: 2, maximum: .seconds(300), jitter: 0.2))
        #expect(config.openDuration.resetAfter == .seconds(300))
        #expect(config.halfOpenProbes == 1)
        #expect(config.halfOpenTimeout == .seconds(60))
        #expect(CircuitBreaker.countsByDefault(Boom.failed))
        #expect(!CircuitBreaker.countsByDefault(Rejection(.bulkheadFull)))
    }

    @Test func aFixedOpenDurationNeverGrows() {
        let fixed = CircuitBreaker.OpenDuration.fixed(.seconds(5))
        for trip in 0..<10 { #expect(fixed.base(forTrip: trip) == .seconds(5)) }
        let exponential = CircuitBreaker.OpenDuration.exponential(initial: .seconds(1), factor: 3, maximum: .seconds(100), jitter: 0)
        #expect((0..<7).map { exponential.base(forTrip: $0) } == [.seconds(1), .seconds(3), .seconds(9), .seconds(27), .seconds(81), .seconds(100), .seconds(100)])
        #expect(exponential.base(forTrip: 1_000_000) == .seconds(100))
    }
}

/// The window against a reference that keeps every call and counts directly.
@Suite("OutcomeWindow")
struct OutcomeWindowTests {
    @Test func aCountWindowMatchesTheLastNCallsOfAReference() {
        for seed in 1...30 as ClosedRange<UInt64> {
            var generator = RandomSource.seeded(seed).generator()
            let capacity = Int.random(in: 1...12, using: &generator)
            var window = OutcomeWindow(lastCalls: capacity)
            var reference: [(failed: Bool, slow: Bool)] = []
            let origin = TestClock().now
            for _ in 0..<300 {
                let failed = Bool.random(using: &generator)
                let slow = Bool.random(using: &generator)
                window.record(failed: failed, slow: slow, at: AnyClock.Instant(offset: origin.offset))
                reference.append((failed, slow))
                let last = reference.suffix(capacity)
                let totals = window.totals(at: AnyClock.Instant(offset: origin.offset))
                #expect(totals.calls == last.count)
                #expect(totals.failures == last.filter(\.failed).count)
                #expect(totals.slowCalls == last.filter(\.slow).count)
            }
        }
    }

    @Test func aTimeWindowMatchesTheBucketsOfAReference() {
        for seed in 1...30 as ClosedRange<UInt64> {
            var generator = RandomSource.seeded(seed).generator()
            let span = Duration.milliseconds(Int.random(in: 1000...20000, using: &generator))
            var window = OutcomeWindow(lastSpan: span)
            let width = span.attoseconds / Int128(OutcomeWindow.bucketCount)
            var reference: [(epoch: Int, failed: Bool, slow: Bool)] = []
            var now = Duration.zero
            for _ in 0..<400 {
                now += .milliseconds(Int.random(in: 0...(span.components.seconds > 0 ? 4000 : 400), using: &generator))
                let instant = AnyClock.Instant(offset: now)
                let epoch = Int(now.attoseconds / width)
                if Int.random(in: 0..<3, using: &generator) > 0 {
                    let failed = Bool.random(using: &generator)
                    let slow = Bool.random(using: &generator)
                    window.record(failed: failed, slow: slow, at: instant)
                    reference.append((epoch, failed, slow))
                }
                let inside = reference.filter { $0.epoch > epoch - OutcomeWindow.bucketCount && $0.epoch <= epoch }
                let totals = window.totals(at: instant)
                #expect(totals.calls == inside.count, "seed \(seed)")
                #expect(totals.failures == inside.filter(\.failed).count)
                #expect(totals.slowCalls == inside.filter(\.slow).count)
            }
        }
    }

    @Test func ratesAreComparedExactly() {
        var totals = OutcomeWindow.Totals()
        totals.calls = 3
        totals.failures = 1
        #expect(!totals.failureRate(atLeast: 333_334))
        #expect(totals.failureRate(atLeast: 333_333))
        totals.calls = 0
        #expect(!totals.failureRate(atLeast: 1))
    }
}
