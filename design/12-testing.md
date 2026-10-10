# 12 · Testing

A robustness library is only as good as the evidence that its guarantees
hold, and the code built on it is only as good as the tests its users can
write. Both depend on the same thing: making time, randomness and failure
controllable.

## What `StoicTesting` provides

| Tool                                  | For                                                                                                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TestClock`                           | Anything that races work against time. Moves only when the test moves it; `waitForSleepers(count:)` is the exact way to know woken work has settled. |
| `ImmediateClock`                      | Recording the delays a policy chose. Every sleep returns at once — so never for timeouts.                                                            |
| `withTestAmbient(clock:seed:events:)` | One call that installs a clock, a seed, recorded events and fresh retry budgets.                                                                     |
| `@Test(.stoic(seed:))`                | The same isolation as a Swift Testing trait, with `StoicTest.events`.                                                                                |
| `RecordingInstrumentation`            | Asserting on decisions, not only results: `events.names`, `events(named:)`.                                                                          |
| `FaultInjector`                       | Scripted failures, latency, hangs, and hangs that ignore cancellation.                                                                               |
| `TestGate`                            | Sequencing steps, and modelling work that cannot be interrupted.                                                                                     |
| `StateGraph.explore`                  | Exhaustive exploration of a state machine's transitions.                                                                                             |

## How Stoic tests itself

- **Every failure-mode row has a test**, on virtual time where time is
  involved.
- **Properties for arithmetic and state.** Schedules over 300 generated
  configurations; seeded jitter reproducibility; budget accounting; schema
  round trips and sparse fixed points over hundreds of generated values;
  an exhaustive 255-combination accumulation test; a differential check of
  the JSON Schema export against an independent validator.
- **Stress.** Every concurrency suite must pass
  `swift test --filter <Suite> --maximum-repetitions 300 --repeat-until fail`.
  This found three real races during development (a cancellation cause
  recorded too late, a semaphore waiter cancelled between deadline and
  enqueue, a ledger shared across repeated runs) — each fixed at its cause,
  never by a sleep.
- **Process-wide state is isolated per test** (budgets in the ambient
  context; unique labels for process-wide ledgers), so tests can repeat and
  run in parallel.
- **No real sleeps as synchronisation.** Tests wait on clocks, gates and
  results.

## Planned

- **A task ledger and `assertQuiescent()`.** Every Stoic-owned task
  registered with its label and owner; a test's teardown asserts nothing is
  left running, no sleeper is pending, no scope is open and no work is
  abandoned — leaks become test failures that name their owner.
- **Deterministic simulation.** Run the tasks Stoic starts on a seeded
  executor (`withTaskExecutorPreference`) that chooses the next runnable job
  from the seed and drives the `TestClock`, with named fault points in
  every primitive (FoundationDB's "buggify"). A failing seed reproduces the
  exact interleaving. The main actor and actors with their own executors
  ignore executor preference; that limit is documented, not hidden.
- **Executable failure-mode tables.** The tables in `design/` as data that
  generates the documentation, test skeletons and a coverage gate: a row
  without a test fails the build.
- **Golden traces.** Asserting the sequence of events a scenario produces.
- **Model-based state-machine testing.** Random event sequences against an
  invariant, shrunk to the shortest failing sequence.
