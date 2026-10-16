/// Transforms every element with at most `limit` transforms running at once,
/// returning the results in the elements' order.
///
/// Elements are started in order, and a new one starts as soon as any
/// running transform finishes, so the pool stays full. On the first failure
/// the rest are cancelled and awaited, and that failure is thrown as
/// `.failed` — failures caused by the cancellation are not failures. Every
/// failure seen while the rest wound down is reported with it, in a
/// `map.failed` event (`first`, then `also_1`, `also_2`, …). To run
/// everything regardless and inspect each outcome, use
/// ``mapConcurrentResults(_:limit:label:transform:)``.
///
/// A cancelled caller stops the map: no element is started once the caller
/// is cancelled, and the running ones are cancelled and awaited. The call
/// then throws `.rejected(.cancelled)` (`.deadlineExceeded` when an enclosing
/// deadline did it), whatever `Failure` is: the library's spelling of
/// cancellation where the error type cannot be a `CancellationError`. It
/// returns only when every element has a result, so the array is always as
/// long as `elements` — a call cancelled after every element finished
/// returns them all.
///
/// Unlike an unbounded task group, this keeps memory, sockets and threads
/// proportional to `limit`, not to the size of the input.
///
/// - Throws: `.failed` with the first failure, or `.rejected` when the
///   caller's cancellation (or deadline) left an element without a result.
public nonisolated(nonsending) func mapConcurrent<C: Collection, R: Sendable, Failure: Error>(
    _ elements: C,
    limit: Int,
    label: String? = nil,
    fileID: String = #fileID,
    line: UInt = #line,
    transform: @escaping @concurrent @Sendable (C.Element) async throws(Failure) -> R
) async throws(PolicyError<Failure>) -> [R] where C.Element: Sendable {
    let map = await boundedMap(Array(elements), limit: limit, stopOnFailure: true, transform: transform)
    if let first = map.failures.first {
        // The event is bounded: past a handful the extra errors are only counted.
        let others = map.failures.dropFirst().prefix(8).enumerated().map { offset, failure in
            Event.Field("also_\(offset + 1)", .error(failure))
        }
        Ambient.record(Event("map.failed", level: .notice, label: label, fields: [
            .init("elements", .int(map.outcomes.count)),
            .init("failures", .int(map.failures.count)),
            .init("first", .error(first)),
        ] + others, fileID: fileID, line: line))
        throw .failed(first)
    }
    var values: [R] = []
    values.reserveCapacity(map.outcomes.count)
    for outcome in map.outcomes {
        // Anything but a success here is the caller's cancellation: an
        // element it left unstarted, or one whose failure it caused.
        guard case .success(let value)? = outcome else {
            throw .rejected(Rejection(.cancelled, label: label).attributingDeadline())
        }
        values.append(value)
    }
    return values
}

/// Transforms every element with at most `limit` transforms running at once,
/// and returns every outcome in the elements' order. A failure does not stop
/// the others.
///
/// A cancelled caller starts no further element, and the running ones are
/// cancelled and awaited. If that left an element without an outcome, the
/// call throws `.cancelled` (`.deadlineExceeded` when an enclosing deadline
/// did it) rather than return an array shorter than `elements`.
///
/// - Throws: A ``Rejection`` when the caller's cancellation (or deadline)
///   left an element unstarted.
public nonisolated(nonsending) func mapConcurrentResults<C: Collection, R: Sendable, Failure: Error>(
    _ elements: C,
    limit: Int,
    label: String? = nil,
    transform: @escaping @concurrent @Sendable (C.Element) async throws(Failure) -> R
) async throws(Rejection) -> [Result<R, Failure>] where C.Element: Sendable {
    let map = await boundedMap(Array(elements), limit: limit, stopOnFailure: false, transform: transform)
    var outcomes: [Result<R, Failure>] = []
    outcomes.reserveCapacity(map.outcomes.count)
    for outcome in map.outcomes {
        // Unstarted elements (nil) can only be a cancelled caller's.
        guard let outcome else { throw Rejection(.cancelled, label: label).attributingDeadline() }
        outcomes.append(outcome)
    }
    return outcomes
}

/// What the engine of both maps saw.
private struct BoundedMap<R, Failure: Error> {
    /// One slot per element: `nil` for an element that never ran because
    /// an earlier one failed or the caller was cancelled, or (when stopping
    /// on failure) whose failure the caller's cancellation caused.
    var outcomes: [Result<R, Failure>?]
    /// When stopping on failure: the failure that stopped the map, then
    /// those of the others as they wound down, cancellations left out.
    var failures: [Failure] = []
}

/// The engine of both maps.
private nonisolated(nonsending) func boundedMap<Element: Sendable, R: Sendable, Failure: Error>(
    _ elements: [Element],
    limit: Int,
    stopOnFailure: Bool,
    transform: @escaping @concurrent @Sendable (Element) async throws(Failure) -> R
) async -> BoundedMap<R, Failure> {
    precondition(limit >= 1, "mapConcurrent needs a limit of at least one")
    let cause = CancellationCauseBox()
    return await withTaskGroup(of: (Int, Result<R, Failure>).self) { group in
        var map = BoundedMap<R, Failure>(outcomes: [Result<R, Failure>?](repeating: nil, count: elements.count))
        var next = 0
        var stopped = false

        func startNext() {
            guard !stopped, !Task.isCancelled, next < elements.count else { return }
            let index = next
            let element = elements[index]
            next += 1
            group.addTask {
                await CancellationCauseBox.$current.withValue(cause) {
                    do throws(Failure) {
                        return (index, .success(try await transform(element)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
        }

        for _ in 0..<min(limit, elements.count) { startNext() }
        while let (index, outcome) = await group.next() {
            if stopped {
                // Draining: cancelled work's outcome is not reported, but a
                // failure of its own is.
                if case .failure(let failure) = outcome, !containsCancellation(failure) {
                    map.failures.append(failure)
                }
                continue
            }
            if stopOnFailure, case .failure(let failure) = outcome {
                // A cancelled caller's children fail because it was
                // cancelled: that is its cancellation, not their failure.
                // Its children are cancelled already; none starts again.
                if Task.isCancelled { continue }
                stopped = true
                map.failures.append(failure)
                cause.record(.siblingFailed)
                group.cancelAll()
                continue
            }
            map.outcomes[index] = outcome
            startNext()
        }
        return map
    }
}
