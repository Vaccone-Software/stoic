@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// `perform`: the deadline, the retry loop and its classifier, and what an
/// error says about the backend's side (design/22).
///
/// Each test declares its own backend: names are process-wide (design/22,
/// State), so two tests never share one by accident.
@Suite("Perform")
struct PerformTests {
    // MARK: Deadline

    @Test(.failureMode("design/22", "the caller set no deadline"))
    func theDefaultDeadlineApplies() async throws {
        let backend = Backend.remote("perform.default-deadline")
        let download = backend.readOnly("download", length: .long)
        let run = try await simulated { _ in
            await withUrgency(.interactive) { await performing(download, Script([.hang])) }
        }
        // A long interactive call to a remote backend: three times 10 s.
        #expect(run.elapsed == .seconds(30))
        #expect(run.value.error?.stopName == "deadline_exceeded")
        #expect(run.value.error?.attempts == 1)
    }

    @Test(.failureMode("design/22", "the caller set a deadline"))
    func theCallersDeadlineWinsShorterOrLonger() async throws {
        let backend = Backend.remote("perform.caller-deadline")
        let download = backend.readOnly("download", length: .long)
        for limit in [Duration.seconds(5), .seconds(45)] {
            let run = try await simulated { _ in
                await withUrgency(.interactive) {
                    await withDeadline(.after(limit)) { await performing(download, Script([.hang])) }
                }
            }
            #expect(run.elapsed == limit)
            #expect(run.value.error?.stopName == "deadline_exceeded")
        }
    }

    @Test(.failureMode("design/22", "a local or compute operation hangs with no caller deadline"))
    func aHungLocalOrComputeOperationEndsAtTheDefaultDeadline() async throws {
        let store = Backend.local("perform.hung-local").readOnly("query")
        let model = Backend.compute("perform.hung-compute").readOnly("infer")
        let run = try await simulated { _ in
            await withUrgency(.interactive) {
                (await performing(store, Script([.hang])), await performing(model, Script([.hang])))
            }
        }
        // 2 s for the store, then 30 s for the model, both at interactive.
        #expect(run.elapsed == .seconds(32))
        #expect(run.value.0.error?.stopName == "deadline_exceeded")
        #expect(run.value.1.error?.stopName == "deadline_exceeded")
    }

    @Test(.failureMode("design/22", "a .long operation is slow"))
    func aSlowLongOperationIsBoundedOnlyByTheDeadline() async throws {
        let transfer = Backend.remote("perform.slow-long").idempotent("transfer", length: .long)
        let run = try await simulated { _ in
            await withUrgency(.interactive) {
                // 25 s: far past the brief attempt timeout (4 s), inside the
                // long deadline (30 s).
                await performing(transfer, Script([.after(.seconds(25), .succeed)]))
            }
        }
        #expect(run.value.success == 1)
        #expect(run.elapsed == .seconds(25))
    }

    // MARK: Repeat safety

    @Test(.failureMode("design/22", "a .notRepeatable operation fails after reaching the backend"))
    func aNonRepeatableFailureAfterReachingTheBackendIsNotRepeated() async throws {
        let send = Backend.remote("perform.not-repeatable-reached").notRepeatable("send")
        let run = try await simulated { _ in
            (await performing(send, Script([.fail(Permanent())])), await performing(send, Script([.fail(Transient())])))
        }
        let declined = try #require(run.value.0.error)
        #expect(declined.stopName == "failed")
        #expect(declined.outcome == .executed)
        #expect(declined.attempts == 1)
        #expect(declined.last is Permanent)
        // A transient failure would be retried for any other operation; this
        // one may have acted, so it is not, and the outcome is unknown.
        let lost = try #require(run.value.1.error)
        #expect(lost.stopName == "failed")
        #expect(lost.attempts == 1)
        #expect(lost.outcome == .unknown)
    }

    @Test(.failureMode("design/22", "a .notRepeatable operation fails before reaching the backend"))
    func aNonRepeatableFailureBeforeReachingTheBackendIsRepeated() async throws {
        let send = Backend.remote("perform.not-repeatable-unreached").notRepeatable("send")
        let script = Script([.fail(Offline()), .fail(Offline()), .succeed])
        let run = try await simulated { _ in
            await withUrgency(.utility) { await performing(send, script) }
        }
        #expect(run.value.success == 3)
        let failing = Script([.fail(Offline())])
        let exhausted = try await simulated { _ in
            await withUrgency(.utility) { await performing(send, failing) }
        }
        let error = try #require(exhausted.value.error)
        #expect(error.attempts == 4)   // the utility schedule's attempts
        #expect(error.outcome == .notExecuted)
        #expect(error.stopName == "failed")
    }

    @Test func aReadOnlyOperationRetriesTransientFailuresAndStopsOnPermanentOnes() async throws {
        let fetch = Backend.remote("perform.read-only").readOnly("fetch")
        let transient = Script([.fail(Transient()), .succeed])
        let permanent = Script([.fail(Permanent())])
        let run = try await simulated { _ in
            await withUrgency(.userInitiated) {
                (await performing(fetch, transient), await performing(fetch, permanent))
            }
        }
        #expect(run.value.0.success == 2)
        #expect(run.value.1.error?.attempts == 1)
        #expect(run.value.1.error?.outcome == .executed)
    }

    @Test func anUnclassifiedFailureIsRetriedRemotelyAndNotLocally() async throws {
        let remote = Backend.remote("perform.unclassified-remote").readOnly("fetch")
        let local = Backend.local("perform.unclassified-local").readOnly("query")
        let run = try await simulated { _ in
            await withUrgency(.userInitiated) {
                (await performing(remote, Script([.fail(Unclassified())])), await performing(local, Script([.fail(Unclassified())])))
            }
        }
        #expect(run.value.0.error?.attempts == 3)
        #expect(run.value.1.error?.attempts == 1)
    }

    @Test func aDefectStopsAtOnce() async throws {
        let fetch = Backend.remote("perform.defect").readOnly("fetch")
        let run = try await simulated { _ in await performing(fetch, Script([.fail(Broken())])) }
        let error = try #require(run.value.error)
        #expect(error.attempts == 1)
        #expect(containsDefect(error))
    }

    // MARK: Keys

    @Test(.failureMode("design/22", "a .keyed operation is repeated"))
    func everyAttemptOfAKeyedOperationSendsOneKey() async throws {
        let charge = Backend.remote("perform.keyed-repeated").keyed("charge")
        let script = Script([.fail(Transient()), .fail(Transient()), .succeed])
        let run = try await simulated { _ in
            await withUrgency(.userInitiated) { await performing(charge, script) }
        }
        #expect(run.value.success == 3)
        #expect(script.keys.count == 3)
        #expect(Set(script.keys).count == 1)
    }

    @Test(.failureMode("design/22", "a .keyed operation is given a key"))
    func everyAttemptSendsTheGivenKey() async throws {
        let charge = Backend.remote("perform.keyed-given").keyed("charge")
        let key = IdempotencyKey(rawValue: "checkout-7")
        let script = Script([.fail(Transient()), .fail(Transient()), .succeed])
        let run = try await simulated { _ in
            await withUrgency(.userInitiated) { await performing(charge, script, key: key) }
        }
        #expect(run.value.success == 3)
        #expect(script.keys == [key, key, key])
    }

    @Test(.failureMode("design/22", "a .keyed operation's drawn key is never read and it fails transiently"))
    func aKeyedOperationThatSendsNoKeyIsNotRepeated() async throws {
        let charge = Backend.remote("perform.keyed-unread").keyed("charge")
        let script = Script([.fail(Transient())], readsKey: false)
        let events = RecordingInstrumentation()
        // Under withTestAmbient the event fails the test: it is a bug.
        await withKnownIssue {
            let result = await withTestAmbient(clock: TestClock(), events: events) {
                await performing(charge, script)
            }
            let error = try #require(result.error)
            #expect(error.attempts == 1)
            #expect(error.idempotencyKey == nil)
            #expect(error.outcome == .unknown)
        }
        #expect(script.count == 1)
        #expect(events.events(named: "operation.key_unread").first?.level == .error)
    }

    @Test(.failureMode("design/22", "a keyed attempt's connection is lost after sending"))
    func aLostConnectionLeavesTheOutcomeUnknown() async throws {
        let charge = Backend.remote("perform.keyed-lost").keyed("charge")
        let key = IdempotencyKey(rawValue: "order-1")
        let run = try await simulated { _ in
            await withUrgency(.interactive) { await performing(charge, Script([.fail(Transient())]), key: key) }
        }
        let error = try #require(run.value.error)
        #expect(error.attempts == 2)
        #expect(error.outcome == .unknown)
        #expect(error.idempotencyKey == key)
        #expect(!error.isCancellation)
    }

    @Test(.failureMode("design/22", "a keyed attempt reaches the backend and times out, and the schedule ends"))
    func aTimedOutKeyedAttemptIsUnknownAndNeverCancellation() async throws {
        let charge = Backend.remote("perform.keyed-timeout").keyed("charge")
        let key = IdempotencyKey(rawValue: "order-2")
        let run = try await simulated { context in
            let result = await withUrgency(.interactive) { await performing(charge, Script([.hang]), key: key) }
            return (result, context.events.events(named: "operation.outcome_unknown").count)
        }
        let error = try #require(run.value.0.error)
        #expect(error.attempts == 2)
        #expect(error.stopName == "failed")
        #expect(error.outcome == .unknown)
        #expect(!error.isCancellation)
        #expect(!containsCancellation(error))
        #expect(!Report(error).isCancellation)
        #expect(run.value.1 == 1)
    }

    // MARK: Device conditions

    @Test(.failureMode("design/22", "the device is under thermal pressure"))
    func delaysStretchOnlyWhereNobodyWaits() async throws {
        let fetch = Backend.remote("perform.thermal").readOnly("fetch")
        func delays(_ urgency: Urgency, _ thermal: SystemConditions.Thermal) async throws -> [Duration] {
            let run = try await simulated(seed: 5) { context in
                _ = await withAmbient({ $0.conditions = FixedConditions(SystemConditions(thermal: thermal)) }) {
                    await withUrgency(urgency) { await performing(fetch, Script([.fail(Transient())])) }
                }
                return context.events.events(named: "retry.attempt_failed").compactMap { event -> Duration? in
                    if case .duration(let delay)? = event["delay"] { return delay }
                    return nil
                }
            }
            return run.value
        }
        let calm = try await delays(.interactive, .nominal)
        #expect(!calm.isEmpty)
        #expect(try await delays(.interactive, .serious) == calm)
        let patient = try await delays(.background, .nominal)
        let stretched = try await delays(.background, .serious)
        #expect(stretched.count == patient.count)
        #expect(zip(patient, stretched).allSatisfy { $1 == min($0 * 2, .seconds(60)) })
        #expect(zip(patient, stretched).contains { $1 > $0 })
    }

    // MARK: Cancellation

    @Test(.failureMode("design/22", "the caller is cancelled during a brief keyed attempt"))
    func aBriefKeyedAttemptFinishesShieldedWhenItsCallerIsCancelled() async throws {
        let charge = Backend.remote("perform.keyed-shielded").keyed("charge")
        let clock = TestClock()
        let finished = SendableBox(false)
        let task = Task {
            await withTestAmbient(clock: clock) {
                await withUrgency(.interactive) {
                    do throws(OperationError<any Error>) {
                        return Result<Int, OperationError<any Error>>.success(try await charge.perform(idempotencyKey: IdempotencyKey(rawValue: "k")) { _ throws(any Error) -> Int in
                            try await Ambient.sleep(for: .seconds(1))
                            finished.mutate { $0 = true }
                            throw Permanent()
                        })
                    } catch {
                        return Result<Int, OperationError<any Error>>.failure(error)
                    }
                }
            }
        }
        // The attempt sleeps; its timer (4 s) and the deadline wait too.
        await clock.waitForSleepers(count: 2)
        task.cancel()
        await clock.advance(by: .seconds(1))
        let error = try #require(await task.value.error)
        #expect(finished.value)
        #expect(error.stopName == "cancelled")
        #expect(error.attempts == 1)
        #expect(error.outcome == .executed)   // what it answered
    }

    @Test func otherAttemptsAreCancelledAtOnce() async throws {
        let fetch = Backend.remote("perform.read-cancelled").readOnly("fetch")
        let clock = TestClock()
        let task = Task {
            await withTestAmbient(clock: clock) { await performing(fetch, Script([.hang])) }
        }
        await clock.waitForSleepers(count: 2)
        task.cancel()
        let error = try #require(await task.value.error)
        #expect(error.stopName == "cancelled")
        #expect(error.isCancellation)
        #expect(error.outcome == .unknown)
        #expect(clock.now.offset == .zero)
    }

    @Test(.failureMode("design/22", "the caller is cancelled during a backoff"))
    func aCancelledBackoffEndsAtOnceAndRefundsItsToken() async throws {
        let backend = Backend.remote("perform.cancelled-backoff")
        let fetch = backend.readOnly("fetch")
        let clock = TestClock()
        let task = Task {
            await withTestAmbient(clock: clock) {
                await withUrgency(.background) {
                    let before = RetryBudget.named(backend.name).available() ?? 0
                    let result = await performing(fetch, Script([.fail(Transient())]))
                    return (result, before, RetryBudget.named(backend.name).available() ?? 0)
                }
            }
        }
        // The backoff after the first attempt failed: the only sleep under a
        // second. The attempt's own timer may never have begun, or still be
        // asleep, so counting sleeps cannot say whether the backoff has.
        await waitUntil("the backoff never began") { clock.pendingDeadlines.contains { $0.offset < .seconds(1) } }
        task.cancel()
        let (result, before, after) = await task.value
        let error = try #require(result.error)
        #expect(error.stopName == "cancelled")
        #expect(error.attempts == 1)
        #expect(clock.now.offset == .zero)
        // The token spent on the retry came back; the first attempt's
        // deposit stays.
        #expect(abs(after - (before + 0.2)) < 0.0001)
    }
}
