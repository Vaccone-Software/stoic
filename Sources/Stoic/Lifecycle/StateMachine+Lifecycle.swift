extension StateMachine {
    /// A machine that runs `lifecycle` live, in memory, from `initial`: the
    /// same definition a stored record is read by, with `whileIn` work,
    /// observation and history as any machine has.
    ///
    ///     let attendance = StateMachine(Attendance.self, initial: .signedUp(eventEnds: end))
    ///
    /// Entering a state arms its timeout on the machine's clock, the initial
    /// state's included. An `.at(m)` timeout is measured on the wall clock
    /// when the state is entered (`Moment.now` to `m`, at least zero) and
    /// then slept on the machine's own clock. `.refuse` reads as `.ignore`:
    /// a live machine has no caller to tell. Its transitions are not
    /// committed anywhere; a live machine that needs "once" across a crash
    /// is a stored record.
    ///
    /// For a definition with no effects; one with effects is run by
    /// ``init(_:initial:label:historyLimit:clock:perform:)``.
    public convenience init<L: Lifecycle>(
        _ lifecycle: L.Type, initial: State, label: String = L.name, historyLimit: Int = 64, clock: AnyClock? = nil
    ) where L.State == State, L.Event == Event, L.Effect == Never {
        self.init(initial: initial, label: label, historyLimit: historyLimit, clock: clock) { state, event in
            Self.live(L.self, L.transition(from: state, on: event), perform: nil)
        }
        if let timeout = L.timeout(in: initial) { armInitialTimeout(Self.liveTimeout(L.self, timeout)) }
    }

    /// A machine that runs `lifecycle` live and hands each effect its
    /// transitions owe to `perform`: once each, in transition order,
    /// outside the machine's lock and after observers hear of the state.
    /// Nothing is durable. See ``init(_:initial:label:historyLimit:clock:)``.
    public convenience init<L: Lifecycle>(
        _ lifecycle: L.Type, initial: State, label: String = L.name, historyLimit: Int = 64, clock: AnyClock? = nil,
        perform: @escaping @Sendable (L.Effect) -> Void
    ) where L.State == State, L.Event == Event {
        self.init(initial: initial, label: label, historyLimit: historyLimit, clock: clock) { state, event in
            Self.live(L.self, L.transition(from: state, on: event), perform: perform)
        }
        if let timeout = L.timeout(in: initial) { armInitialTimeout(Self.liveTimeout(L.self, timeout)) }
    }

    /// A definition's step as a live machine's.
    private static func live<L: Lifecycle>(
        _: L.Type, _ step: LifecycleStep<L>, perform: (@Sendable (L.Effect) -> Void)?
    ) -> (Transition<State, Event>, effects: (@Sendable () -> Void)?) where L.State == State, L.Event == Event {
        func owed(_ effects: [L.Effect]) -> (@Sendable () -> Void)? {
            guard let perform, !effects.isEmpty else { return nil }
            return { for effect in effects { perform(effect) } }
        }
        switch step {
        case .to(let next, let effects):
            return (.to(next, timeout: L.timeout(in: next).map { liveTimeout(L.self, $0) }), owed(effects))
        case .stay(let effects):
            return (.stay, owed(effects))
        case .refuse, .ignore:
            return (.ignore, nil)
        case .invalid(let reason):
            return (.invalid(reason), nil)
        }
    }

    /// A definition's timeout as a live one: `.at` measured on the wall
    /// clock now.
    private static func liveTimeout<L: Lifecycle>(_: L.Type, _ timeout: LifecycleTimeout<L.Event>) -> StateTimeout<Event>
    where L.Event == Event {
        switch timeout {
        case .after(let duration, let event):
            StateTimeout(after: max(.zero, duration), send: event)
        case .at(let moment, let event):
            StateTimeout(after: max(.zero, Moment.now.duration(to: moment)), send: event)
        }
    }
}
