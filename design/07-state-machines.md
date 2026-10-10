# 07 · State machines

Make illegal states unrepresentable, and make work belong to a state. A
lifecycle tracked in a handful of booleans — `isOpen`, `isListening`,
`isClosing`, `heardSomething` — has 2ⁿ combinations, most of them
impossible and some of them reachable anyway. Work started in one phase
leaks into the next, and every callback compares a generation counter to
find out whether it still matters.

## Origin

- **Erlang's gen_statem.** States, events, and state timeouts as part of
  the transition: "if still in this state after T, this event happens".
- **Statecharts and XState.** Activities that run _while in_ a state.
- **Model checking.** A pure transition function can be explored
  exhaustively; TLA+ found AWS bugs needing 35-step traces.

## API

```swift
public enum Transition<State, Event> { case to(State, timeout: StateTimeout<Event>? = nil), stay, ignore, invalid(String) }

public final class StateMachine<State: Hashable & Sendable, Event: Sendable>: Sendable {
    public init(initial: State, label: String, historyLimit: Int = 64, clock: AnyClock? = nil,
                transition: @escaping @Sendable (State, Event) -> Transition<State, Event>)
    public var state: State { get }
    public var history: [Record] { get }
    public func send(_ event: Event)
    public func whileIn(_ state: State, label: String, _ work: @escaping @Sendable (Sender) async -> Void)
    public func whileIn(where: @escaping @Sendable (State) -> Bool, label: String, _ work: …)
    public func states() -> AsyncStream<State>
}

public struct StateGraph<State, Event> {
    public static func explore(from: State, events: [Event], maximumStates: Int = 10_000,
                               transition: (State, Event) -> Transition<State, Event>) -> StateGraph
    public let states: [State]; public let edges: [Edge]; public let invalid: [InvalidPair]
    public func unreachable(of declared: some Sequence<State>) -> [State]
    public var deadEnds: [State]
    public var mermaid: String
}
```

## Semantics

**The transition function is the specification.** A `switch` over
`(state, event)`, checked for exhaustiveness by the compiler and free of
side effects. `ignore` drops an event that means nothing here; `invalid`
marks one that should be impossible, reported at error level
(`statemachine.invalid`) without moving the machine.

**Visits.** Each entry into a state is a new visit, numbered. Re-entering
the same state (`.to(current)`) is a new visit; `.stay` is not.

**Work belongs to a visit.** `whileIn` work starts on every entry to a
matching state and is cancelled with cause `stateExited` on exit. The
`Sender` it receives delivers events only during that visit; a late event
from an earlier visit is dropped and reported (`statemachine.stale_event`).
This is what replaces generation counters: the machine does the
comparison, every time, so no callback can forget to.

**State timeouts.** `.to(state, timeout: .init(after:, send:))` arms a
timer on the machine's clock for that visit; leaving cancels it.

**Concurrency.** The machine is `Sendable`: events may come from any task
and are applied one at a time, in order, under a lock. Events are reported
outside the lock, so an instrumentation sink can never deadlock it.
`states()` streams the current state with newest-only buffering — a UI
wants where the machine is, not every step it took.

**Exploration.** `StateGraph.explore` runs the transition function over
every event in every reachable state. A test asserts there are no invalid
pairs it did not expect, no unreachable declared states (`CaseIterable`),
and no dead ends; the same graph renders as a Mermaid diagram for the docs.
This is model checking at the scale a state machine needs.

## Typestate

For a single resource with an ordered protocol (open → committed or rolled
back), the compiler can do more than a runtime machine: a `~Copyable` type
whose transitions are `consuming` methods makes "commit twice" or "use after
close" a compile error. Use a `StateMachine` for lifecycles driven by
events; use typestate for values whose protocol a single caller drives.

## Failure modes

| What happens if…                              | Behaviour                                            |
| --------------------------------------------- | ---------------------------------------------------- |
| an event is invalid in the current state      | Reported at error level; the machine stays           |
| a state is left while its work runs           | The work is cancelled (`stateExited`)                |
| the work sends an event after its visit ended | Dropped; `statemachine.stale_event`                  |
| a state's timeout elapses during its visit    | The machine sends itself the timeout event           |
| the state is left before its timeout          | The timer is cancelled; no event                     |
| a thousand tasks send events at once          | Applied one at a time; none lost                     |
| the machine is deallocated                    | Its state work is cancelled and its observers finish |
| a declared state can never be reached         | `StateGraph.unreachable(of:)` lists it in a test     |

## Testing

Transitions and history; invalid events; cancellation of state work with
its cause; stale-event rejection across visits; timeouts that fire and
timeouts cancelled by leaving; observation; a thousand concurrent senders;
exploration, unreachable states, invalid pairs, dead ends, the Mermaid
output, and truncation at the state limit. 300 repetitions are clean.

## Planned

- `@StateMachine` macro: declare transitions as a table and get the
  `switch`, the graph checks at compile time, and the diagram.
- Model-based testing in `StoicTesting`: random event sequences against
  an invariant, shrinking a failing sequence to the shortest.
