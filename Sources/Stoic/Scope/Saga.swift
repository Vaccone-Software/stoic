/// A sequence of steps whose effects are undone, in reverse, if the whole
/// does not complete.
///
/// Each step pairs an action with its compensation. When the saga's body
/// returns, the compensations are discarded. When it throws or is
/// cancelled, the compensations of every step that completed run, newest
/// first — shielded from cancellation, each bounded in time, and each run
/// even if an earlier one failed.
///
///     try await withSaga { saga in
///         let order = try await saga.step { try await orders.create(cart) }
///                                 compensate: { order in try await orders.cancel(order) }
///         let charge = try await saga.step { try await payments.charge(order) }
///                                  compensate: { charge in try await payments.refund(charge) }
///         try await shipping.schedule(order, paidBy: charge)   // if this throws, refund, then cancel
///     }
///
/// Compensations are not transactions: they run in this process, and are
/// lost if it dies. For effects that must be undone across a crash, record
/// the steps durably and compensate on the next launch.
public struct Saga: ~Copyable {
    let state: ScopeState

    /// Performs `action`; if the saga later fails, `compensate` undoes it.
    public func step<R: Sendable, Failure: Error>(
        label: String = #function,
        timeout: Duration? = nil,
        _ action: nonisolated(nonsending) () async throws(Failure) -> R,
        compensate: @escaping @Sendable (R) async throws -> Void
    ) async throws(Failure) -> R {
        let value = try await action()
        state.register(Finalizer(label: label, timeout: timeout, runsOn: .failureOnly) { _ in
            try await compensate(value)
        })
        return value
    }
}

/// Runs `body` as a saga. See ``Saga``.
///
/// Compensation failures are reported (`saga.compensation_failed`, through
/// the scope's `scope.finalizer_failed` event) and do not stop the remaining
/// compensations; the body's error passes through unchanged.
public nonisolated(nonsending) func withSaga<R, Failure: Error>(
    exitBudget: Duration = .seconds(30),
    stepTimeout: Duration = .seconds(10),
    label: String? = nil,
    _ body: nonisolated(nonsending) (borrowing Saga) async throws(Failure) -> R
) async throws(Failure) -> R {
    let state = ScopeState(label: label ?? "saga", exitBudget: exitBudget, finalizerTimeout: stepTimeout)
    let saga = Saga(state: state)
    let result: Result<R, Failure>
    do throws(Failure) {
        result = .success(try await body(saga))
    } catch {
        result = .failure(error)
    }
    await state.exit(result.exit)
    return try result.get()
}
