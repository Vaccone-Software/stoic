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
| `simulate(seed:)`, `simulate(seeds:)` | Deterministic simulation: every interleaving decided by a seed, virtual time, deadlocks and livelocks reported, a failing seed replayed exactly.       |

## Deterministic simulation

FoundationDB tested its database for years in a simulator before trusting
real machines with it, and TigerBeetle and Antithesis made the method
famous: run the whole system on one thread, let a seed choose every
ordering, make time virtual, and a failing seed becomes a recording of the
bug. Concurrency bugs live in rare orderings; a stress run reaches them once
in thousands of tries, a simulation explores hundreds of orderings a second
and replays any of them on demand.

```swift
try await simulate(seeds: 0..<500) { sim in
    let engine = SyncEngine(store: FakeStore())
    try await engine.syncAll()
    try #require(engine.pending.isEmpty)   // #require: a failing #expect does not stop the seed
}
// simulation with seed 137 threw after 412 steps, 31.5 seconds of virtual
// time: … Reproduces: simulate(seed: 137)
```

**How it works.** A `TaskExecutor` queues every job instead of running it;
a driver on one dedicated thread takes the next job from among all runnable
ones by the seed, and runs it. When nothing is runnable, it moves the
`TestClock` to the next deadline and wakes its sleepers — so time is
virtual and an hour of backoff takes milliseconds. The body and its
structured children run there by executor preference, actors without their
own executor follow the task calling them, and every task Stoic starts
follows `Ambient.taskExecutor` (unstructured tasks do not inherit a
preference, so Stoic passes it on).

**What it reports.**

- `threw`: the body failed. `simulate(seeds:)` runs the failing seed again
  and says whether it reproduced at the same step.
- `stalled`: nothing runnable, nothing asleep, and nothing arrived from
  outside within `limits.stall` of real time — a deadlock, or a wait on
  something the simulation does not drive. Lists the Stoic tasks still
  running, by label.
- `virtualTimeLimit`: still going after `limits.virtualTime` — a livelock,
  such as a retry without a bound or a timer that re-arms itself.
- `stepLimit`, `cancelled`.

A run that succeeds returns the value with its step count, virtual time,
a fingerprint of every scheduling decision (equal fingerprints, equal
paths) and the Stoic tasks still running when the body returned — almost
always a leak. After a failure the body is cancelled and its cleanup still
runs simulated, bounded.

**Fault points (buggify).** Scheduling explores orderings; it cannot make a
finalizer slow or a retry attempt late. So Stoic's primitives carry named
fault points where timing decides the path — `semaphore.arriving`,
`singleflight.arriving`, `channel.send`, `slot.deliver`, `scope.finalizer`,
`statemachine.work`, `service.start`, `supervisor.child`, `retry.attempt`.
Under simulation (`faults: .standard`) each site is switched on for a
quarter of runs, chosen by the seed, and fires a quarter of the times it is
reached: a few yields, or up to a second of virtual time. `faultsFired`
says which fired. Outside a simulation a fault point is one relaxed atomic
load. The test that proves it: a scope whose finalizer has a 100 ms
timeout passes 200 seeds without faults and fails within 200 with them,
reproducibly — the finalizer was slow to start and was abandoned, so the
resource was still open after the scope returned.

**Reviewed.** An adversarial review found, and the tests now pin: the body
did not inherit the caller's task-locals (it is now started in the
caller's context); a perpetually runnable task left behind turned a
finished body into a step-limit failure (the body's end now ends the run);
virtual time raced ahead of work handed to Dispatch (time now stands still
while `abandoningAfter` work is outstanding, until it proves wedged); and
primitives cancelled sets of tasks in dictionary order, which changes with
each process's hash seed, so a seed did not replay across processes (they
now go in key order, and the fingerprint includes each job's arrival
number, so a different path cannot hide behind the same fingerprint).
Failures inside the body must throw: use `#require`, or throw — a failing
`#expect` is recorded but does not fail the seed.

**Limits, stated rather than hidden.** The main actor and actors with their
own executors run where they always do; so do `Task {}` started by app code
(start it from a Stoic primitive, or with `Task(executorPreference:
Ambient.current.taskExecutor)`), Dispatch, real I/O and real clocks. Work
arriving from there is waited for, but its timing is not seeded, so such a
run may not replay exactly; the fingerprint says when it did not. A job
that blocks its thread blocks the simulation.

**Verified.** The same seed gives the same trace, step count, virtual time
and fingerprint; twenty seeds give many distinct interleavings of a scenario
with a task group, an actor, a semaphore and a jittered retry; a read–yield–
write lost update is found within 200 seeds and reproduces; a deadlock is
reported with the stuck state work by name; a livelock hits the time limit.

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
- **More fault points.** Store writes torn or failing under simulation
  (the simulated file system already can), and a policy that targets the
  sites a failing seed hit, to shrink it.
- **Smarter scheduling.** Uniform choice finds shallow bugs fast; PCT-style
  priority schedules find deep ones with known probability. And shrinking:
  replay a failing seed with fewer preemptions until the minimal ordering
  remains.
- **Executable failure-mode tables.** The tables in `design/` as data that
  generates the documentation, test skeletons and a coverage gate: a row
  without a test fails the build.
- **Golden traces.** Asserting the sequence of events a scenario produces.
- **Model-based state-machine testing.** Random event sequences against an
  invariant, shrunk to the shortest failing sequence.
