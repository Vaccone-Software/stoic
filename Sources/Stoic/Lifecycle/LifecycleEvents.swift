/// The events a lifecycle's decisions report: from ``LifecycleStore/update(_:attempts:_:)``,
/// from a store that commits on its own (`settleDue`), and from a live
/// machine. The pure functions report nothing.
///
/// States and events are written as descriptions at `.private` privacy,
/// because their payloads can name people (an email address); revisions,
/// counts and durations are public. A principal, a reason and an effect are
/// never written.
package enum LifecycleEvents {
    /// A change was committed: what it did, and what it brought to light.
    package static func committed<L: Lifecycle>(_ change: LifecycleChange<L>) {
        if let first = change.entries.first, let last = change.entries.last {
            Ambient.record(level: .debug) {
                Event("lifecycle.applied", level: .debug, label: L.name, fields: [
                    .init("from", .string("\(first.from)"), privacy: .private),
                    .init("event", .string("\(last.event)"), privacy: .private),
                    .init("to", .string("\(last.to)"), privacy: .private),
                    .init("entries", .int(change.entries.count)),
                    .init("effects", .int(change.effects.count)),
                    .init("revision", .int(Int(truncatingIfNeeded: change.record.revision))),
                ])
            }
        }
        let timed = change.entries.filter { $0.by == .timeout }
        if let first = timed.first {
            Ambient.record(Event("lifecycle.timed_out", level: .info, label: L.name, fields: [
                .init("count", .int(timed.count)),
                .init("first_due", .string(first.at.description), privacy: .public),
                .init("lateness", .duration(max(.zero, first.at.duration(to: change.at)))),
            ]))
        }
        if let behind = change.clockBehind {
            clockBehind(L.self, by: behind)
        }
        if let event = change.refusedTimeout {
            timeoutRefused(L.self, state: change.record.written.state, event: event)
        }
    }

    /// A state's own timeout fell due and did not move it.
    package static func timeoutRefused<L: Lifecycle>(_: L.Type, state: L.State, event: L.Event) {
        Ambient.record(Event("lifecycle.timeout_refused", level: .error, label: L.name, fields: [
            .init("state", .string("\(state)"), privacy: .private),
            .init("event", .string("\(event)"), privacy: .private),
        ]))
    }

    /// A moment was raised to the latest one already seen.
    package static func clockBehind<L: Lifecycle>(_: L.Type, by behind: Duration) {
        Ambient.record(Event("lifecycle.clock_behind", level: .notice, label: L.name, fields: [
            .init("behind", .duration(behind)),
        ]))
    }

    /// The definition, or the record's version, did not let a change be made.
    package static func refused<L: Lifecycle>(_ refusal: LifecycleRefusal<L>) {
        switch refusal {
        case .refused(let state, let event, _):
            Ambient.record(Event("lifecycle.refused", level: .info, label: L.name, fields: [
                .init("state", .string("\(state)"), privacy: .private),
                .init("event", .string("\(event)"), privacy: .private),
                .init("kind", .string("refused"), privacy: .public),
            ]))
        case .ignored(let state, let event):
            Ambient.record(Event("lifecycle.refused", level: .info, label: L.name, fields: [
                .init("state", .string("\(state)"), privacy: .private),
                .init("event", .string("\(event)"), privacy: .private),
                .init("kind", .string("ignored"), privacy: .public),
            ]))
        case .invalid(let state, let event, _):
            Ambient.record(Event("lifecycle.invalid", level: .error, label: L.name, fields: [
                .init("state", .string("\(state)"), privacy: .private),
                .init("event", .string("\(event)"), privacy: .private),
            ]))
        case .newerDefinition(let written, let current):
            Ambient.record(Event("lifecycle.newer_definition", level: .warning, label: L.name, fields: [
                .init("written", .int(written)),
                .init("current", .int(current)),
            ]))
        case .chainTooLong(let state, let steps):
            Ambient.record(Event("lifecycle.chain_truncated", level: .error, label: L.name, fields: [
                .init("state", .string("\(state)"), privacy: .private),
                .init("steps", .int(steps)),
            ]))
        }
    }

    /// A commit lost to another writer: notice, and warning on the last
    /// attempt, when `update` gives up.
    package static func conflict<L: Lifecycle>(_: L.Type, attempt: Int, of attempts: Int) {
        Ambient.record(Event("lifecycle.conflict", level: attempt == attempts ? .warning : .notice, label: L.name, fields: [
            .init("attempt", .int(attempt)),
            .init("attempts", .int(attempts)),
        ]))
    }
}
