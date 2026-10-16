/// The acknowledgement that an operation may safely run more than once at the
/// same time.
///
/// ``hedge(_:after:maxAttempts:budget:label:fileID:line:operation:)`` starts a
/// second copy of an operation while the first is still running, so it must
/// be safe to run twice. The argument has a single case so that hedging
/// something that is not safe means writing `.idempotent` over a lie, where a
/// reviewer will see it.
public enum Idempotency: Sendable, Hashable {
    /// Running the operation more than once leaves the same result as once.
    case idempotent
}

/// Starts another attempt of a slow operation, without giving up on the first.
///
/// Attempt 1 starts at once. If no attempt has succeeded `delay` after the
/// most recent one started, the next starts — the earlier ones keep running —
/// up to `maxAttempts`. The first success wins; every other attempt is
/// cancelled with cause ``CancellationCause/superseded`` and awaited, so
/// `hedge` never returns while an attempt is still running. This is the
/// hedged request of "The Tail at Scale": a little extra load, spent only
/// when something is slow, to cut the slow tail.
///
/// **Hedging answers slowness, not failure.** When an attempt fails and no
/// other attempt is running, `hedge` throws that failure at once instead of
/// starting the next on a timer. Failure is `retry`'s business, with a
/// schedule and a budget; a hedge that quietly retried would double the load
/// on a dependency exactly when it is failing. If every attempt that ran
/// failed, the failure thrown is the first to complete, as ``race(label:fileID:line:_:_:)`` does.
///
/// **Hedges are budgeted.** The first attempt deposits into `budget` and each
/// hedge spends a token, exactly as a retry does, so hedging cannot amplify
/// load during an outage beyond the budget's ratio. With no token there is no
/// hedge, and the attempts already running carry on. No hedge starts that
/// could not finish before ``Deadline/current``: one as slow as the attempt
/// still running would end after it, so it would only add load.
///
/// **Retry outside, hedge inside.** Each hedged attempt runs as an attempt,
/// so a `retry` inside one is nested and makes a single attempt. A retry
/// inside a hedge would otherwise turn failures into slowness (its backoff),
/// which the hedge answers with a second copy that retries in full too:
/// twice the load on a failing dependency. Put the `retry` around the
/// `hedge`; a hedge started inside a retry's attempt shares its key scheme
/// (its key is derived from the retry's, the same on every retry attempt).
///
///     let profile = try await hedge(.idempotent, after: .milliseconds(150)) { attempt in
///         try await client.get(profileURL, hedged: attempt.isRetry)
///     }
///
/// The operation runs in child tasks and may run several times at once, so it
/// is `@Sendable` and `@concurrent`, and its result must be `Sendable`.
///
/// - Parameters:
///   - idempotency: Must be `.idempotent`.
///   - delay: How long after an attempt starts, with no success, the next starts.
///   - maxAttempts: The most attempts started, the first included.
///   - budget: Where hedges draw their tokens.
///   - label: Names the hedge in events.
///   - fileID: The call site, captured for events.
///   - line: The call site, captured for events.
///   - operation: One attempt; it receives which attempt it is.
public nonisolated(nonsending) func hedge<R: Sendable, Failure: Error>(
    _ idempotency: Idempotency,
    after delay: Duration,
    maxAttempts: Int = 2,
    budget: RetryBudget = .perCallSite,
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    operation: @escaping @concurrent @Sendable (Attempt) async throws(Failure) -> R
) async throws(Failure) -> R {
    precondition(maxAttempts >= 1, "hedge needs at least one attempt")
    precondition(delay >= .zero, "hedge's delay cannot be negative")
    let ambient = Ambient.current
    let clock = ambient.clock
    let storage = budget.resolved(fileID: fileID, line: line, registry: ambient.budgets)
    storage?.deposit()
    let start = clock.now
    let cause = CancellationCauseBox()
    // Every hedged copy is the same operation, so they share one key; inside
    // another operation's attempt, the key is derived from that operation's.
    let identity = OperationIdentity.starting(fileID: fileID, line: line)

    func report(_ name: EventName, _ fields: [Event.Field], level: Event.Level = .info) {
        ambient.instrumentation.record(Event(name, level: level, label: label, fields: fields, fileID: fileID, line: line))
    }

    let (winner, failures, started) = await withTaskGroup(of: HedgeChild<R, Failure>.self) { group in
        var started = 0
        var running = 0
        var winner: (attempt: Int, value: R)?
        var failures: [Failure] = []

        func startAttempt() {
            started += 1
            running += 1
            let attempt = Attempt(number: started, elapsed: start.duration(to: clock.now), operation: identity)
            group.addTask {
                // A live attempt: a retry inside it is nested and collapses.
                await identity.running(attempt: attempt.number) {
                    await CancellationCauseBox.$current.withValue(cause) {
                        do throws(Failure) {
                            return .attempt(attempt.number, .success(try await operation(attempt)))
                        } catch {
                            return .attempt(attempt.number, .failure(error))
                        }
                    }
                }
            }
        }

        func startTimer() {
            let from = clock.now
            group.addTask {
                do {
                    try await clock.sleep(until: from.advanced(by: delay), tolerance: nil)
                    return .tick
                } catch {
                    return .timerStopped
                }
            }
        }

        startAttempt()
        if maxAttempts > 1 { startTimer() }

        while let child = await group.next() {
            switch child {
            case .attempt(let number, let result):
                running -= 1
                guard winner == nil else { break }   // a cancelled loser's fallout is not a failure
                switch result {
                case .success(let value):
                    winner = (number, value)
                    cause.record(.superseded)
                    group.cancelAll()
                case .failure(let failure):
                    failures.append(failure)
                    report("hedge.attempt_failed", [
                        .init("attempt", .int(number)),
                        .init("running", .int(running)),
                        .init("error", .error(failure)),
                    ], level: .debug)
                    if running == 0 {
                        // Nothing is left to wait for: failure is retry's
                        // business, not a reason to hedge.
                        group.cancelAll()
                    }
                }

            case .tick:
                guard winner == nil, running > 0, started < maxAttempts else { break }
                // Retry's rule: no attempt that could not finish in time. No
                // attempt has finished yet, so one takes at least as long as
                // the first has been running.
                if let deadline = Deadline.current, start.duration(to: clock.now) >= deadline.remaining {
                    report("hedge.deadline_skip", [
                        .init("attempt", .int(started + 1)),
                        .init("remaining", .duration(max(.zero, deadline.remaining))),
                    ], level: .notice)
                    break
                }
                if let storage, storage.withdraw(clock: clock) == nil {
                    report("hedge.budget_exhausted", [.init("attempts", .int(started))], level: .warning)
                    break
                }
                startAttempt()
                report("hedge.started", [
                    .init("attempt", .int(started)),
                    .init("elapsed", .duration(start.duration(to: clock.now))),
                ])
                if started < maxAttempts { startTimer() }

            case .timerStopped:
                break
            }
        }
        return (winner, failures, started)
    }

    if let winner {
        if started > 1 {
            report("hedge.won", [
                .init("attempt", .int(winner.attempt)),
                .init("started", .int(started)),
                .init("latency", .duration(start.duration(to: clock.now))),
            ])
        }
        return winner.value
    }
    report("hedge.all_failed", [
        .init("attempts", .int(started)),
        .init("first", .error(failures[0])),
    ], level: .notice)
    throw failures[0]
}

private enum HedgeChild<R: Sendable, Failure: Error>: Sendable {
    case attempt(Int, Result<R, Failure>)
    case tick
    case timerStopped
}
