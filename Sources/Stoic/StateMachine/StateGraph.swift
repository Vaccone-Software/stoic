/// Every state a transition function can reach, found without running it.
///
/// Because a ``StateMachine``'s transition function is pure, the machine can
/// be explored exhaustively: start from the initial state, try every event,
/// and follow every transition until no new state appears. The result
/// answers questions a test should ask of every machine:
///
/// - Which states are reachable — and which declared states are not?
/// - Which state and event pairs are ``Transition/invalid(_:)``?
/// - Are there states with no way out?
///
/// It also draws the machine, as a Mermaid diagram for the docs.
///
///     let graph = StateGraph.explore(from: Phase.idle, events: Input.allCases, transition: dictationTransitions)
///     #expect(graph.invalid.isEmpty)
///     #expect(graph.unreachable(of: Phase.allCases).isEmpty)
public struct StateGraph<State: Hashable & Sendable, Event: Sendable>: Sendable {
    /// One transition found.
    public struct Edge: Sendable, Hashable {
        public let from: State
        public let event: String
        public let to: State
        public let timeout: Duration?
    }

    /// One state and event pair the function declared invalid.
    public struct InvalidPair: Sendable, Hashable {
        public let state: State
        public let event: String
        public let reason: String
    }

    /// The states reached, in the order they were discovered.
    public let states: [State]
    /// Every transition between reached states.
    public let edges: [Edge]
    /// Every pair declared invalid.
    public let invalid: [InvalidPair]
    /// Whether exploration stopped at `maximumStates` before finishing.
    public let truncated: Bool

    /// Explores `transition` from `initial`, trying every one of `events`
    /// in every reached state (including events a state's timeouts send).
    public static func explore(
        from initial: State,
        events: [Event],
        maximumStates: Int = 10_000,
        transition: (State, Event) -> Transition<State, Event>
    ) -> StateGraph {
        var states = [initial]
        var seen: Set<State> = [initial]
        var edges: [Edge] = []
        var edgeSet: Set<Edge> = []
        var invalid: [InvalidPair] = []
        var cursor = 0
        var truncated = false
        while cursor < states.count {
            let state = states[cursor]
            cursor += 1
            for event in events {
                switch transition(state, event) {
                case .stay, .ignore:
                    continue
                case .invalid(let reason):
                    invalid.append(InvalidPair(state: state, event: "\(event)", reason: reason))
                case .to(let next, let timeout):
                    let edge = Edge(from: state, event: "\(event)", to: next, timeout: timeout?.after)
                    if edgeSet.insert(edge).inserted { edges.append(edge) }
                    if !seen.contains(next) {
                        guard states.count < maximumStates else { truncated = true; continue }
                        seen.insert(next)
                        states.append(next)
                    }
                }
            }
        }
        return StateGraph(states: states, edges: edges, invalid: invalid, truncated: truncated)
    }

    /// The states in `declared` that exploration never reached.
    public func unreachable(of declared: some Sequence<State>) -> [State] {
        let reached = Set(states)
        return declared.filter { !reached.contains($0) }
    }

    /// Reached states that no event leaves.
    public var deadEnds: [State] {
        let leaving = Set(edges.filter { $0.from != $0.to }.map(\.from))
        return states.filter { !leaving.contains($0) }
    }

    /// The graph as a Mermaid state diagram.
    public var mermaid: String {
        var lines = ["stateDiagram-v2"]
        if let first = states.first { lines.append("    [*] --> \(name(first))") }
        for edge in edges {
            let timeout = edge.timeout.map { " (after \($0))" } ?? ""
            lines.append("    \(name(edge.from)) --> \(name(edge.to)): \(edge.event)\(timeout)")
        }
        return lines.joined(separator: "\n")
    }

    private func name(_ state: State) -> String {
        String(describing: state).map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }
}
