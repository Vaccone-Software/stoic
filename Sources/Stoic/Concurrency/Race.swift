/// One competitor in a ``race(label:fileID:line:_:)``.
///
/// A wrapper, not a bare closure, because Swift does not infer `@Sendable`
/// for closures written inside an array literal; `Racer { … }` gives the
/// type checker the context it needs.
public struct Racer<R: Sendable, Failure: Error>: Sendable {
    let operation: @concurrent @Sendable () async throws(Failure) -> R

    public init(_ operation: @escaping @concurrent @Sendable () async throws(Failure) -> R) {
        self.operation = operation
    }
}

/// Runs both operations at once and returns the first success.
///
/// The losers are cancelled — with ``CancellationCause/superseded`` — and
/// then awaited: `race` never returns while a loser is still running, so it
/// leaks nothing. (A loser that ignores cancellation therefore delays the
/// return; give such work its own timeout.) If every operation fails, `race`
/// throws the first failure, as the typed `throws(Failure)` leaves room for
/// nothing else, and reports every failure it saw, in completion order, in a
/// `race.all_failed` event (`first`, then `also_1`, `also_2`, …).
///
///     let mirror = try await race(
///         { try await download(from: primary) },
///         { try await download(from: secondary) }
///     )
///
/// There are forms for two, three and four operations, and one taking an
/// array of ``Racer``s. (A variadic parameter of closures would be the
/// natural spelling, but it crashes the Swift 6.4 compiler at call sites.)
public nonisolated(nonsending) func race<R: Sendable, Failure: Error>(
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    _ first: @escaping @concurrent @Sendable () async throws(Failure) -> R,
    _ second: @escaping @concurrent @Sendable () async throws(Failure) -> R
) async throws(Failure) -> R {
    try await race(label: label, fileID: fileID, line: line, [Racer(first), Racer(second)])
}

/// Runs three operations at once and returns the first success. See ``race(label:fileID:line:_:_:)``.
public nonisolated(nonsending) func race<R: Sendable, Failure: Error>(
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    _ first: @escaping @concurrent @Sendable () async throws(Failure) -> R,
    _ second: @escaping @concurrent @Sendable () async throws(Failure) -> R,
    _ third: @escaping @concurrent @Sendable () async throws(Failure) -> R
) async throws(Failure) -> R {
    try await race(label: label, fileID: fileID, line: line, [Racer(first), Racer(second), Racer(third)])
}

/// Runs four operations at once and returns the first success. See ``race(label:fileID:line:_:_:)``.
public nonisolated(nonsending) func race<R: Sendable, Failure: Error>(
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    _ first: @escaping @concurrent @Sendable () async throws(Failure) -> R,
    _ second: @escaping @concurrent @Sendable () async throws(Failure) -> R,
    _ third: @escaping @concurrent @Sendable () async throws(Failure) -> R,
    _ fourth: @escaping @concurrent @Sendable () async throws(Failure) -> R
) async throws(Failure) -> R {
    try await race(label: label, fileID: fileID, line: line, [Racer(first), Racer(second), Racer(third), Racer(fourth)])
}

/// Runs every racer at once and returns the first success. See ``race(label:fileID:line:_:_:)``.
public nonisolated(nonsending) func race<R: Sendable, Failure: Error>(
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    _ racers: [Racer<R, Failure>]
) async throws(Failure) -> R {
    let operations = racers.map(\.operation)
    precondition(!operations.isEmpty, "race needs at least one operation")
    let cause = CancellationCauseBox()
    let clock = Ambient.current.clock
    let start = clock.now

    let outcome: (winner: Int, value: R)?
    let failures: [Failure]
    (outcome, failures) = await withTaskGroup(of: (Int, Result<R, Failure>).self) { group in
        for (index, operation) in operations.enumerated() {
            // stoic:allow(unbounded-task-group): a race runs every racer at once by definition; callers pass a few
            group.addTask {
                await CancellationCauseBox.$current.withValue(cause) {
                    do throws(Failure) {
                        return (index, .success(try await operation()))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
        }
        var winner: (Int, R)?
        var failures: [Failure] = []
        while let (index, result) = await group.next() {
            switch result {
            case .success(let value) where winner == nil:
                winner = (index, value)
                cause.record(.superseded)
                group.cancelAll()
            case .success:
                break
            case .failure(let failure) where winner == nil:
                failures.append(failure)
            case .failure:
                break   // a cancelled loser's fallout is not a failure
            }
        }
        return (winner, failures)
    }

    if let outcome {
        Ambient.record(Event("race.won", level: .debug, label: label, fields: [
            .init("winner", .int(outcome.winner)),
            .init("latency", .duration(start.duration(to: clock.now))),
        ], fileID: fileID, line: line))
        return outcome.value
    }
    // The event is bounded: past a handful the extra errors are only counted.
    let others = failures.dropFirst().prefix(8).enumerated().map { offset, failure in
        Event.Field("also_\(offset + 1)", .error(failure))
    }
    Ambient.record(Event("race.all_failed", level: .notice, label: label, fields: [
        .init("operations", .int(operations.count)),
        .init("failures", .int(failures.count)),
        .init("first", .error(failures[0])),
    ] + others, fileID: fileID, line: line))
    throw failures[0]
}
