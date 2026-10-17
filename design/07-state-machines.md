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
    public func whileIn(_ state: State, label: String, shutdownTimeout: Duration = .seconds(5),
                        _ work: @escaping @Sendable (Sender) async -> Void)
    public func whileIn(where: @escaping @Sendable (State) -> Bool, label: String, shutdownTimeout: …, _ work: …)
    public func states() -> AsyncStream<State>
    public func shutdown() async
}

public struct StateGraph<State, Event> {
    public static func explore(from: State, events: [Event], maximumStates: Int = 10_000,
                               transition: (State, Event) -> Transition<State, Event>) -> StateGraph where Event: Hashable
    public let states: [State]; public let edges: [Edge]; public let invalid: [InvalidPair]
    public let isComplete: Bool
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
comparison, every time, so no callback can forget to. Work that captured the
machine and calls its `send` is checked the same way: state work runs under
a task-local naming its machine and visit, inherited by the tasks it starts,
and the machine's own `send` drops their events once that visit has ended.

**Visits never overlap.** Leaving a state cancels its work, and the next
visit's work starts only once that work has stopped — its cleanup included
— so a recorder still closing its file never meets the transcriber that
opens it. The wait is bounded: each piece of work has a `shutdownTimeout`
(five seconds by default, as a supervisor child's), counted from the moment
its visit ended; work that overruns it is abandoned, listed in
`AbandonedWork` until it ends, and reported (`statemachine.work_abandoned`),
and the next visit's work starts. `send` itself never waits: the transition
is immediate, and only the new visit's work waits. A visit that is left
before its work could begin runs none.

**Registration is setup.** `whileIn` is called once, where the machine is
made. Registering work again under a label it already has — for the same
state, or as a predicate — is reported at error level
(`statemachine.duplicate_work`) and ignored, so a view that registers on
every appearance cannot start its work twice per visit.

**An owner ends it.** `shutdown()` cancels the machine's work and timer,
waits for the work to stop (each piece bounded by its `shutdownTimeout`),
finishes every `states()` stream and drops every later event as stale. The
work gets everything it needs from its `Sender` and should not capture the
machine: the machine holds its work, so a strong capture is a cycle that
keeps both alive.

**State timeouts.** `.to(state, timeout: .init(after:, send:))` arms a
timer on the machine's clock for that visit; leaving cancels it.

**Concurrency.** The machine is `Sendable`: events may come from any task
and are applied one at a time, in order, under a lock. Events are reported
outside the lock, so an instrumentation sink can never deadlock it, and the
old visit's work is cancelled outside it too: cancellation runs the work's
cancellation handlers on the cancelling thread, at once, and a handler that
reads the machine (or work observing `states()`, whose stream ends on
cancellation) must not find it locked. The transition function and
`whileIn` predicates do run under the lock; one that uses a machine is a
precondition failure that says so, not the lock's own abort. States are
yielded to `states()` observers outside the lock too, in transition order: a
stream holds its own lock while it runs its termination handler, and the
machine's handler takes the machine's lock.
`states()` streams the current state with newest-only buffering — a UI
wants where the machine is, not every step it took.

**Exploration.** `StateGraph.explore` runs the transition function over
every event in every reachable state, and over the events reached states'
timeouts send. A test asserts first that exploration is complete
(`#expect(graph.isComplete)`: a graph cut off at `maximumStates` would pass
every other check without having looked), then that there are no invalid
pairs it did not expect, no unreachable declared states (`CaseIterable`),
and no dead ends; the same graph renders as a Mermaid diagram for the docs.
This is model checking at the scale a state machine needs. Events are told
apart by value, which is why `explore` needs them `Hashable` (an event enum
without payloads already is; one with payloads synthesises it): telling
them apart by description would explore two events that print alike — a
redacted payload — as one, and silently miss what the second reaches.

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
| the work of an ended visit calls the machine's send | Dropped, as through its `Sender`                |
| a state's timeout elapses during its visit    | The machine sends itself the timeout event           |
| the state is left before its timeout          | The timer is cancelled; no event                     |
| a thousand tasks send events at once          | Applied one at a time; none lost                     |
| state work's cancellation handler uses the machine | Safe: work is cancelled once the lock is released |
| an observer stops listening while the machine moves | Neither waits for the other: states are yielded outside the lock, in order |
| a transition function uses the machine        | Precondition failure naming the rule                 |
| a state is left while its work is still cleaning up | The next visit's work starts once that work has stopped |
| state work does not stop within its shutdown timeout | Abandoned and reported; the next visit's work starts |
| work is registered again under the same label | Reported at error level; ignored              |
| the machine is shut down                      | Work cancelled and awaited (bounded); observers finish; later events dropped |
| the machine is deallocated                    | Its state work is cancelled and its observers finish |
| a declared state can never be reached         | `StateGraph.unreachable(of:)` lists it in a test     |
| two events print the same                     | Both explored: events are told apart by value        |

## Testing

Transitions and history (the ring at several limits); invalid events;
cancellation of state work with its cause; the next visit's work waiting
for the last one's cleanup, abandonment after the shutdown timeout, and
shutdown; stale-event rejection across visits; timeouts that fire and
timeouts cancelled by leaving; observation; a thousand concurrent senders;
exploration, unreachable states, invalid pairs, dead ends, the Mermaid
output, and truncation at the state limit. 300 repetitions are clean.

## Planned

- `@StateMachine` macro: declare transitions as a table and get the
  `switch`, the graph checks at compile time, and the diagram.
- Model-based testing in `StoicTesting`: random event sequences against
  an invariant, shrinking a failing sequence to the shortest.
