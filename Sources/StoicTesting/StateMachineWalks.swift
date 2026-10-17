public import Stoic

/// A sequence of events that breaks an invariant, shrunk to the shortest.
public struct InvariantViolation<State: Hashable & Sendable, Event: Sendable>: Sendable, CustomStringConvertible {
    /// The events, from the initial state, that lead to the violation.
    public let events: [Event]
    /// The state the machine was in when the invariant failed.
    public let state: State
    /// What the invariant said was wrong.
    public let message: String

    public var description: String {
        "after \(events.map { "\($0)" }.joined(separator: " → ")): \(message) (in state \(state))"
    }
}

/// Drives a transition function with random event sequences, checking an
/// invariant after every step, and shrinks the first failure to the
/// shortest sequence that still fails.
///
/// Exhaustive exploration (`StateGraph`) answers "which states are
/// reachable"; random walks answer "can any sequence of events break this
/// property" — including properties of the path, not just the state, and
/// for machines too large to enumerate.
///
///     let violation = randomWalks(from: Phase.idle, events: Input.allCases, seed: 7, transition: transitions) { state, history in
///         state == .transcribing && !history.contains(.heard) ? "transcribing without hearing anything" : nil
///     }
///     #expect(violation == nil, "\(violation!)")
///
/// - Parameters:
///   - initial: The state every walk starts from.
///   - events: The events a walk draws from.
///   - walks: How many random walks to run.
///   - length: The most events in one walk.
///   - seed: Decides every choice, so a failing seed replays the same walks.
///   - transition: The machine's transition function.
///   - invariant: Returns a description of what is wrong, or `nil` if the
///     state (reached by the events so far) is fine. Invalid transitions are
///     reported as violations too.
/// - Returns: The shortest violating sequence found, or `nil`.
public func randomWalks<State: Hashable & Sendable, Event: Sendable>(
    from initial: State,
    events: [Event],
    walks: Int = 1_000,
    length: Int = 40,
    seed: UInt64 = 0,
    transition: (State, Event) -> Transition<State, Event>,
    invariant: (State, [Event]) -> String?
) -> InvariantViolation<State, Event>? {
    precondition(!events.isEmpty, "random walks need at least one event")
    var generator = RandomSource.seeded(seed).generator()

    func run(_ sequence: [Event]) -> InvariantViolation<State, Event>? {
        var state = initial
        var history: [Event] = []
        for event in sequence {
            history.append(event)
            switch transition(state, event) {
            case .to(let next, _):
                state = next
            case .stay, .ignore:
                break
            case .invalid(let reason):
                return InvariantViolation(events: history, state: state, message: "invalid transition: \(reason)")
            }
            if let message = invariant(state, history) {
                return InvariantViolation(events: history, state: state, message: message)
            }
        }
        return nil
    }

    for _ in 0..<walks {
        let sequence = (0..<length).map { _ in events[Int.random(in: 0..<events.count, using: &generator)] }
        guard let failure = run(sequence) else { continue }
        return shrink(failure, run: run)
    }
    return nil
}

/// Removes events one at a time while the sequence still fails, until no
/// single removal keeps it failing.
private func shrink<State, Event>(
    _ failure: InvariantViolation<State, Event>,
    run: ([Event]) -> InvariantViolation<State, Event>?
) -> InvariantViolation<State, Event> {
    var best = failure
    var improved = true
    while improved {
        improved = false
        for index in best.events.indices {
            var candidate = best.events
            candidate.remove(at: index)
            if let smaller = run(candidate), smaller.events.count < best.events.count {
                best = smaller
                improved = true
                break
            }
        }
    }
    return best
}
