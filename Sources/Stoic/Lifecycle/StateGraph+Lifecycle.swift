extension StateGraph where Event: Hashable {
    /// Explores a lifecycle's definition from every one of `starts`, trying
    /// every one of `events` in every reached state, and each reached state's
    /// own timeout.
    ///
    ///     let graph = StateGraph.explore(ParentWaiver.self, from: [.awaitingAddress], events: waiverEvents)
    ///     #expect(graph.isComplete)
    ///     #expect(Set(graph.waitingForever) == [.awaitingAddress, .expired])
    ///     #expect(graph.undeclaredDeadEnds.isEmpty && graph.stuckTimeouts.isEmpty && graph.timedCycles.isEmpty)
    ///
    /// The start states are a list because records can be created in several
    /// (a sign-up, an import), and a retired state is reached only from data
    /// stored before it was retired: list it to check its migration. An
    /// edge a state's timeout took is marked ``Edge/byTimeout``, and carries
    /// the effects the step owes. A `.stay`, `.refuse` and `.ignore` make no
    /// edge, as they make none for a transition function.
    public static func explore<L: Lifecycle>(
        _ lifecycle: L.Type, from starts: [State], events: [Event], maximumStates: Int = 10_000
    ) -> StateGraph where L.State == State, L.Event == Event {
        var states: [State] = []
        var seen: Set<State> = []
        var edges: [Edge] = []
        var edgeSet: Set<Edge> = []
        var invalid: [InvalidPair] = []
        var declarations = Declarations()
        var complete = true

        typealias Attempt = TimedAttempt<Event>
        var queue: [Attempt] = []
        var queued: Set<Attempt> = []
        func enqueue(_ attempt: Attempt) {
            if queued.insert(attempt).inserted { queue.append(attempt) }
        }
        func reach(_ state: State) -> Bool {
            if seen.contains(state) { return true }
            guard states.count < maximumStates else { return false }
            seen.insert(state)
            states.append(state)
            if L.isFinal(state) { declarations.final.insert(state) }
            if L.isRetired(state) { declarations.retired.insert(state) }
            for event in events { enqueue(Attempt(state: state, event: event, byTimeout: false)) }
            if let timeout = L.timeout(in: state) {
                declarations.timed.insert(state)
                enqueue(Attempt(state: state, event: timeout.event, byTimeout: true))
            }
            return true
        }
        for start in starts where !reach(start) { complete = false }

        var cursor = 0
        while cursor < queue.count {
            let attempt = queue[cursor]
            cursor += 1
            switch L.transition(from: attempt.state, on: attempt.event) {
            case .to(let next, let effects):
                let edge = Edge(
                    from: attempt.state, event: "\(attempt.event)", to: next, timeout: nil,
                    byTimeout: attempt.byTimeout, effects: effects.map { "\($0)" })
                if edgeSet.insert(edge).inserted { edges.append(edge) }
                if !reach(next) { complete = false }
            case .stay, .refuse, .ignore:
                if attempt.byTimeout { declarations.stuck.append(attempt.state) }
            case .invalid(let reason):
                invalid.append(InvalidPair(state: attempt.state, event: "\(attempt.event)", reason: reason))
                if attempt.byTimeout { declarations.stuck.append(attempt.state) }
            }
        }
        return StateGraph(
            states: states, edges: edges, invalid: invalid, isComplete: complete, starts: starts,
            declarations: declarations)
    }
}

extension StateGraph {
    /// A state and event pair to try, and whether the state's own timeout
    /// sends the event.
    struct TimedAttempt<E: Hashable>: Hashable {
        let state: State
        let event: E
        let byTimeout: Bool
    }

    /// Reached states that are not final and have no timeout: a wait with
    /// no end. A test asserts this equal to a written list, never empty by
    /// fiat, so a state that can wait forever is a decision in a diff.
    ///
    /// On a graph explored from a transition function, nothing is declared
    /// final, and a state times out when a transition into it arms a
    /// timeout.
    public var waitingForever: [State] {
        guard let declarations else {
            let timed = Set(edges.filter { $0.timeout != nil }.map(\.to))
            return states.filter { !timed.contains($0) }
        }
        return states.filter { !declarations.final.contains($0) && !declarations.timed.contains($0) }
    }

    /// Reached states that nothing leaves and that are not declared final.
    /// On a graph explored from a transition function, every dead end.
    public var undeclaredDeadEnds: [State] {
        let final = declarations?.final ?? []
        return deadEnds.filter { !final.contains($0) }
    }

    /// States declared final that an event or a timeout leaves. Empty for a
    /// graph explored from a transition function, which declares nothing.
    public var finalWithExits: [State] {
        guard let declarations else { return [] }
        let leaving = Set(edges.filter { $0.from != $0.to }.map(\.from))
        return states.filter { declarations.final.contains($0) && leaving.contains($0) }
    }

    /// Cycles made of timeouts alone, each from the first of its states
    /// that exploration reached: periodic work, which belongs to a
    /// `Schedule`, not to a lifecycle. At run time a read stops such a chain
    /// at 64 steps. Empty for a graph explored from a transition function.
    public var timedCycles: [[State]] {
        guard declarations != nil else { return [] }
        // A state has one timeout and a transition is a function, so a
        // state's timeout edges lead to one state: follow them.
        var next: [State: State] = [:]
        for edge in edges where edge.byTimeout { next[edge.from] = edge.to }
        var cycles: [[State]] = []
        var done: Set<State> = []
        for start in states where !done.contains(start) {
            var path: [State] = []
            var onPath: [State: Int] = [:]
            var current: State? = start
            while let state = current, !done.contains(state) {
                if let index = onPath[state] {
                    cycles.append(Array(path[index...]))
                    break
                }
                onPath[state] = path.count
                path.append(state)
                current = next[state]
            }
            done.formUnion(path)
        }
        let order = Dictionary(uniqueKeysWithValues: states.enumerated().map { ($1, $0) })
        return cycles.map { cycle in
            let first = cycle.indices.min { order[cycle[$0], default: 0] < order[cycle[$1], default: 0] } ?? 0
            return Array(cycle[first...] + cycle[..<first])
        }
    }

    /// States whose own timeout's event does not move them (`.stay`,
    /// `.refuse`, `.ignore` or `.invalid`): a read stops there, and a commit
    /// reports `lifecycle.timeout_refused`. Empty for a graph explored from
    /// a transition function.
    public var stuckTimeouts: [State] {
        declarations?.stuck ?? []
    }

    /// Edges into a retired state from one that is not retired: a current
    /// state may never enter a retired one. Empty for a graph explored from
    /// a transition function.
    public var retiredEntries: [Edge] {
        guard let declarations else { return [] }
        return edges.filter { !declarations.retired.contains($0.from) && declarations.retired.contains($0.to) }
    }

    /// Retired states with no timeout that leaves them: a record written in
    /// one would never be migrated. Empty for a graph explored from a
    /// transition function.
    public var retiredWithoutExit: [State] {
        guard let declarations else { return [] }
        let migrating = Set(edges.filter { $0.byTimeout && $0.from != $0.to }.map(\.from))
        return states.filter { declarations.retired.contains($0) && !migrating.contains($0) }
    }
}
