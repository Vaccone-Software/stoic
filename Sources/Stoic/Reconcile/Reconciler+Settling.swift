extension Reconciler {
    /// A job that commits what has fallen due in a lifecycle store, at the
    /// store's moment (design/27, design/30): a server's sweep, given the
    /// app's query.
    ///
    ///     let dueAttendance = Reconciler.settling(attendance, due: Attendance.due) { now, limit, _ in
    ///         try await db.attendance(dueBefore: now, limit: limit)    // a query on the record's `dueAt`
    ///     }
    ///
    /// Each pass reads the store's moment, then the due ids through `query`
    /// (at most `limit`, through the `due` operation), and settles each, in
    /// key order, `concurrency` at a time. Settling is repeatable: a second
    /// settle finds nothing due, or loses a conflict and computes the same
    /// entries and effect keys again. A record whose settle leaves it due
    /// (its timeout does not move it, `lifecycle.timeout_refused`), whose
    /// definition refuses to settle it, or whose settle fails, is refused:
    /// stuck at once, and held back on its backoff, so the loop never spins
    /// on it. A query that returns its limit may have left some: another pass
    /// follows after `coalesce`.
    ///
    /// - Parameters:
    ///   - store: The store whose records' timeouts fall due.
    ///   - due: The query's declared operation. Must be `.readOnly`.
    ///   - schedule: How long after a pass ends the next one runs: 5 minutes,
    ///     with equal jitter, by default; `nextDue` makes it prompt.
    ///   - policy: The bounds: `correctionsPerPass` is the query's limit.
    ///   - nextDue: When the earliest record falls due, if the app can say.
    ///   - query: The ids of records due before the moment, at most `limit`.
    public static func settling<S: LifecycleStore>(
        _ store: S,
        due: Backend.Operation,
        every schedule: Schedule = .fixed(.seconds(300)).jittered(.equal),
        policy: ReconcilePolicy = ReconcilePolicy(),
        nextDue: (@Sendable () async -> Moment?)? = nil,
        query: @escaping @Sendable (_ dueBefore: Moment, _ limit: Int, Attempt) async throws -> [S.ID]
    ) -> Reconciler<S.ID> where Key == S.ID {
        precondition(due.safety == .readOnly, "settling \(S.Definition.name): the due query must be .readOnly, not \(due.safety)")
        return Reconciler<S.ID>(name: "\(S.Definition.name).settling", every: schedule, policy: policy, nextDue: nextDue) { request in
            let now = await store.moment(for: .now)
            let found = try await due.perform { attempt throws(any Error) in try await query(now, request.limit, attempt) }
            // A query may return an id twice; it is settled once.
            let due = Set(found).sorted()
            let ready = due.filter { !request.waiting.contains($0) }
            let results = try await mapConcurrentResults(ready, limit: policy.concurrency, label: "\(S.Definition.name).settling") { id in
                await Self.settle(id, in: store, at: now)
            }
            if Task.isCancelled { throw CancellationError() }
            var refused: [S.ID: String] = [:]
            var settled = 0
            for (id, result) in zip(ready, results) {
                switch result {
                case .success(nil): settled += 1
                case .success(let reason?): refused[id] = reason
                }
            }
            return ReconcileOutcome(
                differences: due.count, corrected: settled, deferred: found.count >= request.limit ? 1 : 0, refused: refused)
        }
    }

    /// Settles one record: `nil` when it is settled (or gone), else why it
    /// could not be.
    private static func settle<S: LifecycleStore>(_ id: S.ID, in store: S, at now: Moment) async -> String? {
        do throws(LifecycleUpdateError<S.Definition, S.Failure>) {
            let record = try await store.settle(id)
            if let due = record.written.dueAt, due <= now { return "its timeout does not move it" }
            return nil
        } catch {
            switch error {
            case .notFound: return nil
            case .refused(let refusal): return "its definition cannot settle it (\(Self.kind(of: refusal)))"
            case .conflict: return "it kept changing under the settle"
            case .storage(let failure): return "the store failed (\(String(reflecting: type(of: failure))))"
            case .cancelled: return "cancelled"
            }
        }
    }

    private static func kind<L: Lifecycle>(of refusal: LifecycleRefusal<L>) -> String {
        switch refusal {
        case .refused: "refused"
        case .ignored: "ignored"
        case .invalid: "invalid"
        case .newerDefinition: "a newer definition wrote it"
        case .chainTooLong: "its timed steps form a cycle"
        }
    }
}
