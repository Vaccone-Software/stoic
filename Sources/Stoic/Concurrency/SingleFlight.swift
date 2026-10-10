internal import Synchronization

/// Concurrent requests for the same key share one execution.
///
/// When ten views ask for the same avatar at once, one download should run
/// and ten callers should get its result. The first caller for a key starts
/// the operation; callers that arrive while it runs join it. When it
/// finishes, the key is cleared: this is deduplication, not caching.
///
/// The shared operation belongs to the flight, not to any one caller:
///
/// - **Cancellation is reference-counted.** A caller that is cancelled, or
///   whose ``Deadline/current`` passes, leaves the flight with a rejection;
///   the operation goes on for the others. Only when the last caller has
///   left is the operation cancelled — and the key is retired at once, so a
///   caller arriving after that starts a fresh flight instead of joining one
///   that is winding down.
/// - **No caller's deadline bounds the others.** The operation runs without
///   the first caller's deadline; each caller's wait is bounded by its own.
///   A flight whose callers have all given up is cancelled, so the
///   operation is never orphaned.
/// - It inherits the first caller's ``Ambient`` context and other task-locals.
///
/// Every caller receives the same value, or the same error.
public final class SingleFlight<Key: Hashable & Sendable, Value: Sendable, Failure: Error>: Sendable {
    /// Names the flight group in events.
    public let label: String

    private typealias Outcome = Result<Value, PolicyError<Failure>>
    private typealias Waiter = CheckedContinuation<Outcome, Never>

    private struct Flight {
        let id: UInt64
        let cause = CancellationCauseBox(parent: nil)
        var task: Task<Void, Never>?
        var waiters: [UInt64: Waiter] = [:]
    }

    private struct State {
        var nextID: UInt64 = 0
        var flights: [Key: Flight] = [:]
        // Callers with an id that have not joined a flight yet, with the
        // rejection (cancellation, deadline) that arrived first, if any.
        var arriving: [UInt64: Rejection?] = [:]
        // The key each joined caller is waiting on.
        var membership: [UInt64: Key] = [:]
    }

    private let state = Mutex(State())

    public init(label: String) {
        self.label = label
    }

    /// The number of keys with an operation in flight.
    public var flightCount: Int {
        state.withLock { $0.flights.count }
    }

    /// The number of callers waiting on `key`'s flight.
    public func waiterCount(for key: Key) -> Int {
        state.withLock { $0.flights[key]?.waiters.count ?? 0 }
    }

    /// Runs `operation` for `key`, or joins the run already in flight.
    ///
    /// - Throws: `.failed` with the shared operation's error, or `.rejected`
    ///   when this caller stopped waiting: `.cancelled`, or
    ///   `.deadlineExceeded` when ``Deadline/current`` passed.
    public nonisolated(nonsending) func run(
        _ key: Key,
        operation: @escaping @concurrent @Sendable () async throws(Failure) -> Value
    ) async throws(PolicyError<Failure>) -> Value {
        if Task.isCancelled { throw .rejected(Rejection(.cancelled, label: label)) }
        let waiterID = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            state.arriving[state.nextID] = .some(nil)
            return state.nextID
        }
        let deadline = Deadline.current
        let outcome: Outcome = await withTaskGroup(of: Void.self) { group in
            if let deadline {
                group.addTask {
                    do {
                        try await deadline.clock.sleep(until: deadline.instant, tolerance: nil)
                        self.leave(waiterID, because: Rejection(.deadlineExceeded, label: self.label))
                    } catch {}
                }
            }
            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { (waiter: Waiter) in
                    join(waiterID, key: key, operation: operation, waiter: waiter)
                }
            } onCancel: {
                leave(waiterID, because: Rejection(.cancelled, label: label))
            }
            group.cancelAll()
            return outcome
        }
        if case .failure(.rejected(let rejection)) = outcome,
           rejection.reason == .cancelled, CancellationCause.current == .deadline {
            throw .rejected(Rejection(.deadlineExceeded, label: label))
        }
        return try outcome.get()
    }

    private func join(
        _ waiterID: UInt64,
        key: Key,
        operation: @escaping @concurrent @Sendable () async throws(Failure) -> Value,
        waiter: Waiter
    ) {
        let next = state.withLock { state -> FlightJoin in
            if let early = state.arriving.removeValue(forKey: waiterID) ?? nil {
                return .rejected(early)
            }
            state.membership[waiterID] = key
            if state.flights[key] != nil {
                state.flights[key]!.waiters[waiterID] = waiter
                return .joined
            }
            let flightID = state.nextID
            state.nextID += 1
            var flight = Flight(id: flightID)
            flight.waiters[waiterID] = waiter
            state.flights[key] = flight
            return .launch(flightID)
        }
        switch next {
        case .rejected(let rejection):
            waiter.resume(returning: .failure(.rejected(rejection)))
        case .joined:
            Ambient.record(Event("singleflight.joined", level: .debug, label: label))
        case .launch(let flightID):
            launch(key: key, flightID: flightID, operation: operation)
        }
    }

    private func launch(key: Key, flightID: UInt64, operation: @escaping @concurrent @Sendable () async throws(Failure) -> Value) {
        let cause = state.withLock { $0.flights[key]?.id == flightID ? $0.flights[key]?.cause : nil }
        guard let cause else { return }   // every caller already left
        let task = TaskLedger.task(.flight, label: label) {
            let result: Result<Value, Failure> = await Deadline.$stored.withValue(nil) {
                await CancellationCauseBox.$current.withValue(cause) {
                    do throws(Failure) {
                        return .success(try await operation())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            self.land(key: key, flightID: flightID, result: result)
        }
        let orphaned = state.withLock { state -> Bool in
            guard state.flights[key]?.id == flightID else { return true }
            state.flights[key]!.task = task
            return false
        }
        if orphaned {
            // Every caller left between the flight's creation and its task's.
            cause.record(.userRequested)
            task.cancel()
        }
    }

    private func leave(_ waiterID: UInt64, because rejection: Rejection) {
        let (waiter, retired) = state.withLock { state -> (Waiter?, Flight?) in
            if let arriving = state.arriving[waiterID] {
                // Not joined yet: it will find this on arrival.
                if arriving == nil { state.arriving[waiterID] = .some(rejection) }
                return (nil, nil)
            }
            guard let key = state.membership.removeValue(forKey: waiterID),
                  var flight = state.flights[key],
                  let waiter = flight.waiters.removeValue(forKey: waiterID) else {
                return (nil, nil)
            }
            if flight.waiters.isEmpty {
                // The last caller left: retire the key now, so newcomers
                // start afresh rather than join a flight being cancelled.
                state.flights[key] = nil
                return (waiter, flight)
            }
            state.flights[key] = flight
            return (waiter, nil)
        }
        waiter?.resume(returning: .failure(.rejected(rejection)))
        if let retired {
            retired.cause.record(.userRequested)
            retired.task?.cancel()
            Ambient.record(Event("singleflight.abandoned", label: label))
        }
    }

    private func land(key: Key, flightID: UInt64, result: Result<Value, Failure>) {
        let waiters = state.withLock { state -> [Waiter] in
            guard let flight = state.flights[key], flight.id == flightID else { return [] }
            state.flights[key] = nil
            for waiterID in flight.waiters.keys { state.membership[waiterID] = nil }
            return Array(flight.waiters.values)
        }
        let outcome: Outcome = result.mapError { .failed($0) }
        for waiter in waiters { waiter.resume(returning: outcome) }
    }
}

private enum FlightJoin {
    case rejected(Rejection)
    case joined
    case launch(UInt64)
}
