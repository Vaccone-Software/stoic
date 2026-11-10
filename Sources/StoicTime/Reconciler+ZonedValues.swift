public import Stoic

extension Reconciler {
    /// A job that keeps future zoned values' instants right under the zone
    /// rules in force (design/26, design/30): level-triggered, so it also
    /// refreshes the values a device or a server wrote under older or newer
    /// rules, which a sweep on a change of version never reaches.
    ///
    ///     let starts = Reconciler.zonedValues(
    ///         name: "kindora.event-starts", reads: Events.starts, writes: Events.restart,
    ///         values: { scope, _ in try await local.upcomingStarts(scope) },     // [EventID: ZonedDateTime]
    ///         write: { moved, _ in try await local.update(starts: moved) })
    ///
    /// Each pass reads the future values through `reads`, refreshes each one
    /// that is stale by its own policy (`isStale`, then `refreshed`), and
    /// writes the moved ones in one call through `writes`. A value whose zone
    /// the rules in force do not know is refused, with the reason, and the
    /// others are written. A full pass checks every value, at microseconds
    /// each; the daily schedule, and the full pass every `run()` starts with,
    /// cover a change of the rules. Meanwhile display and "is it time?" read
    /// the local time and zone, which are never wrong.
    ///
    /// - Parameters:
    ///   - name: Stable forever: the label of its events.
    ///   - reads: The values' declared read. Must be `.readOnly`.
    ///   - writes: The moved values' declared write. Must be `.idempotent`:
    ///     refreshing a refreshed value changes nothing.
    ///   - schedule: How long after a pass ends the next one runs: a day, with
    ///     equal jitter, by default.
    ///   - policy: The bounds and backoffs.
    ///   - values: The future values within the scope, complete or thrown.
    ///   - write: Stores the moved values.
    public static func zonedValues(
        name: String,
        reads: Backend.Operation,
        writes: Backend.Operation,
        every schedule: Schedule = .fixed(.seconds(86_400)).jittered(.equal),
        policy: ReconcilePolicy = ReconcilePolicy(),
        values: @escaping @Sendable (ReconcileScope<Key>, Attempt) async throws -> [Key: ZonedDateTime],
        write: @escaping @Sendable ([Key: ZonedDateTime], Attempt) async throws -> Void
    ) -> Reconciler<Key> {
        precondition(reads.safety == .readOnly, "zoned values \(name): the read must be .readOnly, not \(reads.safety)")
        precondition(writes.safety == .idempotent, "zoned values \(name): the write must be .idempotent, not \(writes.safety)")
        return Reconciler(name: name, every: schedule, policy: policy) { request in
            let given = try await reads.perform { attempt throws(any Error) in try await values(request.scope, attempt) }
            let now = Moment.now
            var moved: [Key: ZonedDateTime] = [:]
            var refused: [Key: String] = [:]
            for (key, value) in given where !request.waiting.contains(key) {
                do throws(TimeError) {
                    guard try value.isStale(now: now) else { continue }
                    moved[key] = try value.refreshed(now: now)
                } catch {
                    refused[key] = "the rules in force cannot resolve it in \(value.zone.identifier)"
                }
            }
            if !moved.isEmpty {
                try await writes.perform { attempt throws(any Error) in try await write(moved, attempt) }
            }
            return ReconcileOutcome(differences: moved.count + refused.count, corrected: moved.count, refused: refused)
        }
    }
}
