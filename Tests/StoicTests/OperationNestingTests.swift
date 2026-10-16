@testable import Stoic
import StoicTesting
import Synchronization
import Testing

/// One layer retries: `perform` inside retries, retries inside `perform`,
/// and `perform` inside `perform` (design/22, One layer retries).
@Suite("Operation nesting")
struct OperationNestingTests {
    /// Counts calls.
    final class Counter: Sendable {
        private let count = Mutex(0)
        @discardableResult func next() -> Int { count.withLock { $0 += 1; return $0 } }
        var value: Int { count.withLock { $0 } }
    }

    @Test(.failureMode("design/22", "perform is called inside another retry's attempt"))
    func performRetriesByItsOwnPolicyInsideARetry() async throws {
        let fetch = Backend.remote("nesting.inside-retry").readOnly("fetch")
        let script = Script([.fail(Transient()), .fail(Transient()), .succeed])
        let outer = Counter()
        let run = try await simulated { _ in
            await withUrgency(.userInitiated) {
                try? await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(OperationError<any Error>) -> Int in
                    outer.next()
                    return try await fetch.perform { attempt throws(any Error) in try await script.call(attempt) }
                }
            }
        }
        #expect(run.value == 3)
        #expect(outer.value == 1)
        #expect(script.count == 3)
    }

    @Test(.failureMode("design/22", "perform throws inside another retry's attempt"))
    func aPerformThatGivesUpSettlesTheEnclosingAttempt() async throws {
        let fetch = Backend.remote("nesting.settles").readOnly("fetch")
        let script = Script([.fail(Transient())])
        let outer = Counter()
        let run = try await simulated { context in
            _ = await withUrgency(.interactive) {
                try? await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(OperationError<any Error>) -> Int in
                    outer.next()
                    return try await fetch.perform { attempt throws(any Error) in try await script.call(attempt) }
                }
            }
            return context.events.events(named: "retry.stopped").map { $0.text("reason") }
        }
        #expect(outer.value == 1)
        #expect(script.count == 2)   // the interactive schedule, once
        #expect(run.value == ["inner_settled"])
    }

    @Test func theSettledMarkPassesThroughACollapsedLayer() async throws {
        // retry → retry (collapses) → perform: the outermost must not repeat.
        let fetch = Backend.remote("nesting.through").readOnly("fetch")
        let script = Script([.fail(Transient())])
        let outer = Counter()
        _ = try await simulated { _ in
            await withUrgency(.interactive) {
                try? await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(OperationError<any Error>) in
                    outer.next()
                    try await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(OperationError<any Error>) in
                        _ = try await fetch.perform { attempt throws(any Error) in try await script.call(attempt) }
                    }
                }
            }
        }
        #expect(outer.value == 1)
        #expect(script.count == 2)
    }

    @Test func retryingAndHedgeNeverRepeatASettledAttempt() async throws {
        let fetch = Backend.remote("nesting.retrying-hedge").readOnly("fetch")
        let send = Backend.remote("nesting.retrying-hedge").notRepeatable("send")
        let viaStage = Counter()
        let viaHedge = Counter()
        _ = try await simulated { _ in
            await withUrgency(.interactive) {
                _ = await outcome(of: Retrying(.fixed(.seconds(1)).attempts(3), budget: .unlimited)) { () throws(OperationError<any Error>) in
                    viaStage.next()
                    _ = try await fetch.perform { attempt throws(any Error) in try await Script([.fail(Transient())]).call(attempt) }
                }
                do throws(OperationError<any Error>) {
                    _ = try await hedge(.idempotent, after: .milliseconds(100), maxAttempts: 5, budget: .unlimited) { _ throws(OperationError<any Error>) -> Int in
                        if viaHedge.next() > 1 {
                            // Later copies are slow and fail.
                            try? await Ambient.sleep(for: .seconds(1))
                            throw OperationError(stop: .cancelled, outcome: .notExecuted, last: nil, attempts: 0, safety: .readOnly, idempotencyKey: nil)
                        }
                        // The first copy gives up at 150 ms and settles its attempt.
                        return try await send.perform { attempt throws(any Error) in
                            try await Script([.after(.milliseconds(150), .fail(Permanent()))]).call(attempt)
                        }
                    }
                } catch {}
            }
        }
        #expect(viaStage.value == 1)
        // The second copy started at 100 ms; none after the first settled.
        #expect(viaHedge.value == 2)
    }

    @Test(.failureMode("design/22", "an enclosing attempt's timeout cuts a .readOnly perform off"))
    func aReadOnlyPerformCutByTheEnclosingTimeoutDoesNotSettle() async throws {
        let download = Backend.remote("nesting.cut-read").readOnly("download", length: .long)
        let outer = Counter()
        _ = try await simulated { _ in
            await withUrgency(.interactive) {
                try? await retry(.fixed(.seconds(1)).attempts(3), attemptTimeout: .seconds(5), budget: .unlimited) { _ throws(OperationError<any Error>) in
                    outer.next()
                    _ = try await download.perform { attempt throws(any Error) in try await Script([.hang]).call(attempt) }
                }
            }
        }
        #expect(outer.value == 3)
    }

    @Test(.failureMode("design/22", "an enclosing attempt's timeout cuts a .notRepeatable perform off after it reached the backend"))
    func aNonRepeatablePerformCutByTheEnclosingTimeoutSettles() async throws {
        let upload = Backend.remote("nesting.cut-unsafe").notRepeatable("upload", length: .long)
        let outer = Counter()
        let run = try await simulated { context in
            await withUrgency(.interactive) {
                try? await retry(.fixed(.seconds(1)).attempts(3), attemptTimeout: .seconds(5), budget: .unlimited) { _ throws(OperationError<any Error>) in
                    outer.next()
                    _ = try await upload.perform { attempt throws(any Error) in try await Script([.hang]).call(attempt) }
                }
            }
            return context.events.events(named: "operation.outcome_unknown").count
        }
        #expect(outer.value == 1)
        #expect(run.value == 1)
    }

    @Test(.failureMode("design/22", "perform runs inside a perform on the same backend"))
    func anInnerPerformOnTheSameBackendBorrowsTheSlotAndMakesOneAttempt() async throws {
        let backend = Backend.remote("nesting.same-backend", capacity: 1)
        let page = backend.readOnly("page")
        let item = backend.readOnly("item")
        let inner = Script([.fail(Transient()), .fail(Transient()), .succeed])
        let outer = Counter()
        let run = try await simulated { _ in
            await withUrgency(.userInitiated) {
                try? await page.perform { _ throws(OperationError<any Error>) -> Int in
                    outer.next()
                    // With one slot, waiting for a slot of its own would wait
                    // for this very call.
                    return try await item.perform { attempt throws(any Error) in try await inner.call(attempt) }
                }
            }
        }
        #expect(run.value == 1)     // the inner call's first and only attempt
        #expect(outer.value == 3)
        #expect(inner.count == 3)   // one attempt per outer attempt
    }

    @Test func overlappingInnerPerformsTakeTheirOwnSlots() async throws {
        let backend = Backend.remote("nesting.overlap", capacity: 4)
        let page = backend.readOnly("page")
        let item = backend.readOnly("item")
        let run = try await simulated { context in
            await withUrgency(.interactive) {
                let value = try? await page.perform { _ throws(OperationError<any Error>) -> Int in
                    async let first = performing(item, Script([.after(.seconds(1), .succeed)]))
                    async let second = performing(item, Script([.after(.seconds(1), .succeed)]))
                    return await [first, second].compactMap(\.success).reduce(0, +)
                }
                return (value, context.events.events(named: "operation.nested_admission").count)
            }
        }
        #expect(run.value.0 == 2)
        #expect(run.value.1 == 1)
    }

    @Test func anInnerWriteUnderAnOuterWriteIsReentrantOnTheLane() async throws {
        let backend = Backend.local("nesting.lane")
        let save = backend.idempotent("save")
        let index = backend.idempotent("index")
        let run = try await simulated { _ in
            try? await save.perform { _ throws(OperationError<any Error>) -> Int in
                try await index.perform { attempt throws(any Error) in try await Script([.succeed]).call(attempt) }
            }
        }
        #expect(run.value == 1)   // no deadlock on the one-writer lane
    }

    @Test(.failureMode("design/22", "a plain retry runs inside perform's operation"))
    func aPlainRetryInsidePerformMakesOneAttempt() async throws {
        let fetch = Backend.remote("nesting.plain-inside").readOnly("fetch")
        let inner = Counter()
        let attempts = try await simulated { _ in
            await withUrgency(.userInitiated) {
                do throws(OperationError<Transient>) {
                    _ = try await fetch.perform { _ throws(Transient) in
                        try await retry(.fixed(.seconds(1)).attempts(5), budget: .unlimited) { _ throws(Transient) in
                            inner.next()
                            throw Transient()
                        }
                    }
                    return 0
                } catch {
                    return error.attempts
                }
            }
        }
        #expect(attempts.value == 3)
        #expect(inner.value == 3)   // one per perform attempt
    }

    @Test(.failureMode("design/22", "an OperationError is caught by a retry that missed the settled mark"))
    func anOperationErrorCarriedAcrossTasksIsNotRetriedUnlessNothingWasExecuted() async throws {
        let fetch = Backend.remote("nesting.carried").readOnly("fetch")
        let executed = Counter()
        let unexecuted = Counter()
        _ = try await simulated { _ in
            await withUrgency(.interactive) {
                // Performed in a task of its own: no enclosing attempt to settle.
                let failed = await withTaskGroup(of: OperationError<any Error>?.self) { group in
                    group.addTask { await Self.detachedFromAttempts { await performing(fetch, Script([.fail(Transient())])).error } }
                    return await group.next()!!
                }
                let offline = await withTaskGroup(of: OperationError<any Error>?.self) { group in
                    group.addTask { await Self.detachedFromAttempts { await performing(fetch, Script([.fail(Offline())])).error } }
                    return await group.next()!!
                }
                #expect(failed.outcome == .unknown)
                #expect(offline.outcome == .notExecuted)
                _ = try? await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(OperationError<any Error>) in
                    executed.next()
                    throw failed
                }
                _ = try? await retry(.fixed(.seconds(1)).attempts(3), budget: .unlimited) { _ throws(OperationError<any Error>) in
                    unexecuted.next()
                    throw offline
                }
            }
        }
        #expect(executed.value == 1)
        #expect(unexecuted.value == 3)
    }

    /// Runs `body` with no attempt in force, as a task started elsewhere would.
    static func detachedFromAttempts<R>(_ body: () async -> R) async -> R {
        await RetryContext.$active.withValue(nil) { await body() }
    }

    @Test(.failureMode("design/22", "the operation's ceiling is below the caller's urgency"))
    func anOperationRunsAtItsCeiling() async throws {
        let reindex = Backend.remote("nesting.ceiling").readOnly("reindex", ceiling: .utility)
        let script = Script([.fail(Transient())])
        let run = try await simulated { context in
            let result = await withUrgency(.interactive) { await performing(reindex, script) }
            return (result, context.events.events(named: "operation.urgency_capped").first)
        }
        #expect(reindex.policy(at: .interactive) == reindex.policy(at: .utility))
        #expect(run.value.0.error?.attempts == 4)   // the utility schedule, not the interactive one
        #expect(run.value.1?.text("urgency") == "interactive")
        #expect(run.value.1?.text("ceiling") == "utility")
    }
}
