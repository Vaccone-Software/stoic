public import Stoic

/// Drives a lifecycle's definition with random walks of events and of time
/// passing, through the record's own `applying(_:by:because:at:)`
/// and `settling(at:)` on a virtual moment, checking an
/// invariant over the state and the committed history after every step;
/// shrinks the first failure to the shortest walk that still fails.
///
///     let violation = randomWalks(ParentWaiver.self, from: .awaitingAddress, by: .staff(admin),
///                                 events: [.send(to: parent), .sign, .revoke]) { state, entries in
///         let sends = entries.filter { $0.to == .sent && $0.entered }.count
///         return entries.flatMap(\.effects).count == sends ? nil : "an email per visit to sent"
///     }
///     #expect(violation == nil, "\(violation!)")
///
/// Each step is an event from `events`, applied by `by` at the current
/// moment (an event refused or ignored changes nothing), or time passing to
/// the next moment a timeout falls due, whose timed entries are then
/// committed. So a property of the path can be checked: "never signed after
/// expired", "one email per visit to `sent`". A walk that meets
/// `.invalid`, a timed chain cut at its cap, or a state's own timeout that
/// does not move it, is a violation.
///
/// In the violation, a step of time passing appears as the timeout events
/// it fired, and is shrunk like an event.
///
/// - Parameters:
///   - lifecycle: The definition.
///   - initial: The state every walk's record is created in.
///   - by: Who sends the events.
///   - events: The events a walk draws from.
///   - walks: How many random walks to run.
///   - length: The most steps in one walk.
///   - seed: Decides every choice, so a failing seed replays the same walks.
///   - invariant: Given the state as read now and every entry committed so
///     far, a description of what is wrong, or `nil`.
/// - Returns: The shortest violating walk found, or `nil`.
/// One step of a lifecycle's random walk: an event (by its index), or time
/// passing.
private enum WalkStep {
    case event(Int)
    case wait
}

public func randomWalks<L: Lifecycle>(
    _ lifecycle: L.Type,
    from initial: L.State,
    by: L.Principal,
    events: [L.Event],
    walks: Int = 1_000,
    length: Int = 40,
    seed: UInt64 = 0,
    invariant: (L.State, [L.Entry]) -> String?
) -> InvariantViolation<L.State, L.Event>? {
    precondition(!events.isEmpty, "random walks need at least one event")
    var generator = RandomSource.seeded(seed).generator()
    // The test clock's wall clock starts here too: a walk's moments read
    // like a test's.
    let start = Moment(sinceEpoch: .seconds(1_767_225_600))
    let key = IdempotencyKey(rawValue: "random-walk-\(seed)")

    func run(_ choices: [WalkStep]) -> (violation: InvariantViolation<L.State, L.Event>?, steps: [WalkStep]) {
        var record = L.Record.new(in: initial, by: by, because: "a random walk", at: start, key: key)
        var now = start
        var entries: [L.Entry] = []
        var happened: [L.Event] = []
        var taken: [WalkStep] = []
        func violation(_ message: String, in state: L.State) -> InvariantViolation<L.State, L.Event> {
            InvariantViolation(events: happened, state: state, message: message)
        }
        for choice in choices {
            taken.append(choice)
            let change: L.Change?
            do throws(L.Refusal) {
                switch choice {
                case .event(let index):
                    happened.append(events[index])
                    change = try record.applying(events[index], by: by, because: "a random walk", at: now)
                case .wait:
                    let reading = record.read(at: now)
                    guard let due = reading.nextDue, due > now else { continue }
                    now = due
                    change = try record.settling(at: now)
                    if change == nil, let event = record.read(at: now).refusedTimeout {
                        return (violation("the state's own timeout (\(event)) does not move it", in: record.written.state), taken)
                    }
                    happened.append(contentsOf: change?.entries.map(\.event) ?? [])
                }
            } catch {
                switch error {
                case .refused, .ignored:
                    change = nil
                case .invalid(let state, _, let reason):
                    return (violation("invalid transition: \(reason)", in: state), taken)
                case .chainTooLong(let state, let steps):
                    return (violation("timed steps stopped at their cap of \(steps)", in: state), taken)
                case .newerDefinition(let written, let current):
                    return (violation("written by version \(written), read by \(current)", in: record.state(at: now)), taken)
                }
            }
            if let change {
                if let event = change.refusedTimeout {
                    return (violation("the state's own timeout (\(event)) does not move it", in: change.record.written.state), taken)
                }
                record = change.record
                entries.append(contentsOf: change.entries)
            }
            let state = record.state(at: now)
            if let message = invariant(state, entries) {
                return (violation(message, in: state), taken)
            }
        }
        return (nil, taken)
    }

    for _ in 0..<walks {
        let choices = (0..<length).map { _ -> WalkStep in
            let pick = Int.random(in: 0...events.count, using: &generator)
            return pick == events.count ? .wait : .event(pick)
        }
        let first = run(choices)
        guard var best = first.violation else { continue }
        // Shrink: drop one step at a time while the walk still fails.
        var steps = first.steps
        var improved = true
        while improved {
            improved = false
            for index in steps.indices {
                var candidate = steps
                candidate.remove(at: index)
                let attempt = run(candidate)
                if let smaller = attempt.violation, attempt.steps.count < steps.count {
                    best = smaller
                    steps = attempt.steps
                    improved = true
                    break
                }
            }
        }
        return best
    }
    return nil
}
