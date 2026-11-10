public import Stoic

extension Reconciler where Key: Codable {
    /// A job that commits what has fallen due in a device's lifecycle store,
    /// in one batch, waking at the store's `nextDue` (design/27, design/30).
    ///
    ///     let releasesDue = Reconciler.settling(releases)
    ///     Child("releases-due") { _ in try await releasesDue.run() }
    ///
    /// Each pass is one `settleDue()`: every due record settled in one batch
    /// append, or none. A record still due once it returns (its timeout does
    /// not move it, its chain is cut, a newer definition wrote it) is refused:
    /// stuck at once, and reported until a pass finds it moved. The store's
    /// `nextDue` leaves such records out, so the loop never spins on them.
    ///
    /// - Parameters:
    ///   - store: The device's store.
    ///   - schedule: How long after a pass ends the next one runs: 15
    ///     minutes, with equal jitter, by default; `nextDue` makes it prompt.
    ///   - policy: The bounds and backoffs.
    public static func settling<L: Lifecycle>(
        _ store: JournaledLifecycleStore<L, Key>,
        every schedule: Schedule = .fixed(.seconds(900)).jittered(.equal),
        policy: ReconcilePolicy = ReconcilePolicy()
    ) -> Reconciler<Key> {
        Reconciler<Key>(name: "\(L.name).settling", every: schedule, policy: policy, nextDue: { await store.nextDue }) { _ in
            let now = Moment.now
            let settled = try await store.settleDue(at: now)
            let moment = await store.moment(for: now)
            var refused: [Key: String] = [:]
            for (id, record) in await store.records() {
                if let due = record.written.dueAt, due <= moment { refused[id] = "its timeout does not move it" }
            }
            return ReconcileOutcome(differences: settled + refused.count, corrected: settled, refused: refused)
        }
    }
}
