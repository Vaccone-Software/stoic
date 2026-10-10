/// Transforms every element with at most `limit` transforms running at once,
/// returning the results in the elements' order.
///
/// Elements are started in order, and a new one starts as soon as any
/// running transform finishes, so the pool stays full. On the first failure
/// the rest are cancelled and awaited, and that failure is thrown — failures
/// caused by the cancellation are not reported as failures. To run
/// everything regardless and inspect each outcome, use
/// ``mapConcurrentResults(_:limit:transform:)``.
///
/// Unlike an unbounded task group, this keeps memory, sockets and threads
/// proportional to `limit`, not to the size of the input.
public nonisolated(nonsending) func mapConcurrent<C: Collection, R: Sendable, Failure: Error>(
    _ elements: C,
    limit: Int,
    transform: @escaping @concurrent @Sendable (C.Element) async throws(Failure) -> R
) async throws(Failure) -> [R] where C.Element: Sendable {
    let outcomes = await boundedMap(Array(elements), limit: limit, stopOnFailure: true, transform: transform)
    var values: [R] = []
    values.reserveCapacity(outcomes.count)
    var firstFailure: Failure?
    for outcome in outcomes {
        switch outcome {
        case .some(.success(let value)): values.append(value)
        case .some(.failure(let failure)): if firstFailure == nil { firstFailure = failure }
        case .none: break
        }
    }
    if let firstFailure { throw firstFailure }
    return values
}

/// Transforms every element with at most `limit` transforms running at once,
/// and returns every outcome in the elements' order. A failure does not stop
/// the others.
public nonisolated(nonsending) func mapConcurrentResults<C: Collection, R: Sendable, Failure: Error>(
    _ elements: C,
    limit: Int,
    transform: @escaping @concurrent @Sendable (C.Element) async throws(Failure) -> R
) async -> [Result<R, Failure>] where C.Element: Sendable {
    await boundedMap(Array(elements), limit: limit, stopOnFailure: false, transform: transform)
        .map { $0! }
}

/// The engine of both maps. Returns one slot per element: `nil` for an
/// element that never ran (or was cancelled) because an earlier one failed.
private nonisolated(nonsending) func boundedMap<Element: Sendable, R: Sendable, Failure: Error>(
    _ elements: [Element],
    limit: Int,
    stopOnFailure: Bool,
    transform: @escaping @concurrent @Sendable (Element) async throws(Failure) -> R
) async -> [Result<R, Failure>?] {
    precondition(limit >= 1, "mapConcurrent needs a limit of at least one")
    let cause = CancellationCauseBox()
    return await withTaskGroup(of: (Int, Result<R, Failure>).self) { group in
        var outcomes = [Result<R, Failure>?](repeating: nil, count: elements.count)
        var next = 0
        var stopped = false

        func startNext() {
            guard !stopped, next < elements.count else { return }
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
                continue   // draining: cancelled work's outcome is not reported
            }
            outcomes[index] = outcome
            if stopOnFailure, case .failure = outcome {
                stopped = true
                cause.record(.siblingFailed)
                group.cancelAll()
                continue
            }
            startNext()
        }
        return outcomes
    }
}
