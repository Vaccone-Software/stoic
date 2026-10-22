# 12 · Testing

A robustness library is only as good as the evidence that its guarantees
hold, and the code built on it is only as good as the tests its users can
write. Both depend on the same thing: making time, randomness and failure
controllable.

## What `StoicTesting` provides

| Tool                                  | For                                                                                                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TestClock`                           | Anything that races work against time. Moves only when the test moves it; `waitForSleepers(count:)` is the exact way to know woken work has settled, and it never hangs silently. |
| `ImmediateClock`                      | Recording the delays a policy chose. Every sleep returns at once — so never for timeouts.                                                            |
| `withTestAmbient(clock:seed:events:)` | One call that installs a clock, a seed, recorded events and fresh retry budgets.                                                                     |
| `@Test(.stoic(seed:))`                | The same isolation as a Swift Testing trait, with `StoicTest.events`.                                                                                |
| `RecordingInstrumentation`            | Asserting on decisions, not only results: `events.names`, `events(named:)`.                                                                          |
| `FaultInjector`                       | Scripted failures, latency, hangs, and hangs that ignore cancellation.                                                                               |
| `TestGate`                            | Sequencing steps, and modelling work that cannot be interrupted.                                                                                     |
| `StateGraph.explore`                  | Exhaustive exploration of a state machine's transitions.                                                                                             |
| `simulate(seed:)`, `simulate(seeds:)` | Deterministic simulation: every interleaving decided by a seed, virtual time, deadlocks and livelocks reported, a failing seed replayed exactly.       |

## Waiting on a `TestClock`

`waitForSleepers(count:)` suspends until *at least* `count` tasks are asleep
on the clock *right now*. After an `advance` that wakes a task which then
sleeps again (a retry's next, jittered delay), a sleeper that was never
woken can satisfy the count while the one the test means has not slept yet.
Take `let mark = clock.totalSleeps` before the advance and wait with
`waitForSleepers(newerThan: mark)`, which counts sleeps *begun* since.

A sleeper that never arrives — the code under test is not on this clock,
or has finished, or an earlier advance already woke it — used to hang the
test until its time limit, a minute later, with nothing printed, and a
cancelled wait returned as if it were satisfied. Both now end the wait with
an issue. `timeout:` (real time, 5 seconds by default; `nil` for none)
bounds it, and the message prints the clock's state: the time, every
sleeper's deadline and how long until it, the number of sleeps begun, and
how many were asked for. A wait that times out also ends every sleep on the
clock, now and later, with `CancellationError`: the test has failed, and work
parked on a clock nobody will move would otherwise hang the run (a time limit
cannot end a test awaiting an unstructured task), where this fails one test. `clock.summary` gives the same text for a test's
own messages. Sleeps carry no labels, so a sleeper is known by its
deadline.

**From XCTest.** A call without a `sourceLocation:` resolves to an overload
that takes `#fileID`, `#filePath`, `#line` and `#column` as plain values, so
an XCTest file calls `await clock.waitForSleepers(count: 1)` with
`import StoicTesting` alone. (The overload that takes a `SourceLocation` has a
`#_sourceLocation` default, which is written into the caller and so needs
`import Testing` there; it stays, disfavoured, for a call that passes one.) A
timeout is still recorded as a Swift Testing issue, which an XCTest run reports
as a failure at the caller's line; the test that proves the overload compiles
without the import is an XCTest file (`TestClockXCTestTests`).

## Failure-mode coverage

Every contract's "What happens if…" table is a list of promises, and a
promise without a test is a defect. A test names the row it proves —
`@Test(.failureMode("design/09", "a child stops beating"))` — and
`FailureModeCoverageTests` parses every table in `design/` on every run:

- a row no test claims fails the suite, unless it is listed in
  `design/failure-modes.baseline`;
- a baseline row that a test now claims fails the suite until it is removed,
  so the baseline only shrinks;
- a claim naming a row that no longer exists — rewritten, misspelt — fails,
  so a contract cannot drift away from its tests.

`STOIC_WRITE_FAILURE_BASELINE=1 swift test --filter FailureModeCoverage`
rewrites the baseline from the current state.

## Deterministic simulation

FoundationDB tested its database for years in a simulator before trusting
real machines with it, and TigerBeetle and Antithesis made the method
famous: run the whole system on one thread, let a seed choose every
ordering, make time virtual, and a failing seed becomes a recording of the
bug. Concurrency bugs live in rare orderings; a stress run reaches them once
in thousands of tries, a simulation explores tens of thousands of small
orderings a second and replays any of them on demand.

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
  outside — a deadlock, or a wait on something the simulation does not
  drive. Lists the Stoic tasks still running, by label. When no job has ever
  been enqueued from another thread, nothing outside has gone to sleep on
  the clock and no `abandoningAfter` work is outstanding, nothing outside
  is likely to take part, and the stall is reported after `limits.quietStall`
  (50 ms) rather than `limits.stall` (two seconds of real time, which a
  hop to a busy main actor may need). Only silence counts toward that window:
  a job arriving, or anything outside registering a sleeper on the
  simulation's clock, wakes the driver and restarts it (an unstructured
  `Task {}` that sleeps on the ambient clock used to be called stalled
  every time, because its sleeper registered after the driver had looked
  and nothing told it). Before the verdict, the driver also checks that the
  cooperative thread pool answers a trivial task, so a busy machine that
  has not yet started the app's task is not mistaken for a deadlock.
  The verdict is real-time, and is therefore only as exact as the machine
  is idle; code that stays inside the simulation never depends on it,
  because nothing outside it exists to be waited for.
- `virtualTimeLimit`: still going after `limits.virtualTime` — a livelock,
  such as a retry without a bound or a timer that re-arms itself.
- `stepLimit`, `cancelled`.

A run that succeeds returns the value with its step count, virtual time,
the schedule it followed, a fingerprint of every scheduling decision (equal
fingerprints, equal paths) and the Stoic tasks still running when the body
returned (`leftover`) — almost always a leak. After a failure the body is
cancelled and its cleanup still runs simulated, bounded. A failure prints
its kind (`kind.name`, and `"\(kind)"` with the error or the stuck tasks).

**Escapes are reported.** Work that leaves the simulation succeeds
silently, and a green run over such work proves less than it looks: the
seed no longer decides the outcome. So `Simulated.report` says what escaped:

- `outsideJobs`: jobs queued onto the simulation's executor from a thread
  other than the driver's (an unstructured `Task {}`, `Task.detached`,
  Dispatch, a Foundation `Timer`, a real-clock sleep, the main actor
  waking the body);
- `outsideSleeps`: sleeps begun on the simulation's clock by such a thread
  (an unstructured task sleeping on the ambient `TestClock`);
- `leftover` and `stuck`, as above;
- `isDeterministic`: no outside arrival, "as far as the simulator can
  tell" — work that never touches the simulation at all (a `Task {}` the
  body never waits for) cannot be seen;
- `description`, which names the likely causes and the fix.

`simulate(seed:)` and `simulate(seeds:)` record a Swift Testing issue when a
run saw outside arrivals or ended with leftover work (`simulate(seeds:)`
records one issue for the whole exploration: the first seed, and how many
others). The fix is to stay inside — `Task(executorPreference:
Ambient.current.taskExecutor) { … }` (Stoic's own `Task.stoic`),
`Ambient.sleep(for:)` or a `clock:` parameter given `sim.clock`, a Stoic
primitive for the lifecycle — or, when the escape is the point (a
`Timer`-driven API, `abandoningAfter`, a hop to the main actor, a leak that
a test pins on purpose), `allowEscapes: true`:

```swift
let run = try await simulate(seed: 7, allowEscapes: true) { _ in try await legacyTimerAPI() }
#expect(!run.isDeterministic)   // and say so: this seed may not replay
```

`abandoningAfter` is on that list: its operation runs on a Dispatch queue,
so its completion always arrives from outside. Virtual time stands still
until it does, but the moment is not seeded.

**Teardown.** When a run ends, success or failure, the simulation cancels
the Stoic tasks of its ledger tag and everything asleep on its clock, and
drives the executor until it is quiet (at most 20,000 steps, a few rounds;
not counted in `steps` or the fingerprint). Without it a task parked on the
clock kept the clock, and itself, alive for the rest of the process, and a
cancelled one never ran its cleanup. `leftover` still means what was
running when the body returned; `stuck` is what was still running after
the unwinding — waiting on a continuation nothing will resume, or ignoring
cancellation. Tasks that are in neither the ledger nor on the clock (a
`Task {}` of the app's, parked on a continuation) cannot be reached.

**Schedules.** Which runnable job goes next is a strategy, chosen by the
seed (`simulate(schedule:)` forces one, and `Simulated.schedule` and
`SimulationFailure.schedule` say which ran):

- *Uniform*: every runnable job equally likely. Tasks stay in lock-step, so
  the bugs that need two tasks to interleave once — a lost update, a check
  and act across an await, an ABA, a missed wakeup — are found in a few
  seeds. It cannot find a bug that needs one task to run many steps while
  another waits at one point: that takes 2⁻ⁿ.
- *PCT* (probabilistic concurrency testing, Burckhardt et al.), depth two
  to four: every task gets a random priority, the highest-priority runnable
  job runs, and at `depth - 1` random picks the task that just ran is
  demoted below everyone. A bug that needs `d` ordering constraints is found
  with probability at least 1/(n·kᵈ⁻¹) for `n` tasks of `k` steps, however
  long the run-ahead is. The runtime has no API for which task a job belongs
  to; the task id is read from `UnownedJob.description`, in one place that
  falls back to uniform choice if the format ever changes. A job that is
  not a task's own — an actor draining its mailbox, what `Task.yield`
  queues to resume its task — takes the priority of the task whose job
  queued it. The run's length is not known in advance, so the change
  points fall within a horizon the seed picks, sixteen steps to eight
  thousand. A task that re-enqueues itself 256 picks in a row (a spin-wait
  on `Task.yield`) is demoted below everything, or the task it waits for
  would never run; demoting at the *first* yield would turn PCT into
  round-robin and lose the run-ahead bugs.
- The default *portfolio* gives half the seeds to uniform and the rest, in
  turn, to PCT at depths two, three and four, so a contiguous seed range
  covers all of them.

Measured over 1,000 seeds, with unrelated suspension points around the
critical section (n tasks, about 400 steps at the worst row):

| bug | uniform | portfolio | pct, depth 2 |
| --- | ---: | ---: | ---: |
| lost update, no padding / 50 steps | 746 / 117 | 488 / 76 | 23 / 5 |
| actor reentrancy, no padding / 50 | 937 / 230 | 621 / 148 | 51 / 6 |
| ABA across two awaits, 50 | 22 | 10 | 2 |
| missed wakeup, 50 | 64 | 42 | 2 |
| 3-lock deadlock, 50 | 24 | 15 | 4 |
| one task 10 yields ahead of another's one | **0** | 143 | 405 |
| … 40 yields ahead | **0** | 97 | 297 |

The portfolio keeps about two thirds of uniform's hits on the classics and
finds what uniform never does. PCT alone is worse on the classics, which
is expected: it runs one task ahead unless a change point lands exactly
in the window.

**Early timers.** Virtual time otherwise passes only when nothing is
runnable, so work always beats a timeout: "the timer fires in the middle of
the computation" could never be explored. On half the seeds (chosen
independently of the strategy) the next deadline may also fire while jobs
are still runnable, with probability 1 in 8, 32 or 128 at each step and at
most 32 times per run (so progress is never starved), and never while
`abandoningAfter` work is outstanding. Earliest deadline first, so order
among timers is still causal. A 1 ms timeout against ten steps of work: 0
of 1,000 seeds without early timers, 252 with. `schedule:
.uniform` (or `.pct(depth:)`) turns them off; `.earlyTimers(true)` turns
them on.

**Fault points (buggify).** Scheduling explores orderings; it cannot make a
finalizer slow or a retry attempt late. So Stoic's primitives carry named
fault points where timing decides the path — `semaphore.arriving`,
`admission.arriving`, `singleflight.arriving`, `channel.send`,
`slot.deliver`, `scope.finalizer`, `statemachine.work`, `service.start`,
`supervisor.child`, `retry.attempt`.
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

**Cost.** About three million steps a second, 30 µs for a tiny run (release
build). PCT reads each job's description, so a PCT run is several times
slower per step. A timer heap in `TestClock` makes 30,000 sleepers with
distinct deadlines fire in 0.11 s (19.7 s when each fire scanned them all).

**Limits, stated rather than hidden.** The main actor and actors with their
own executors run where they always do; so do `Task {}` started by app code
(start it from a Stoic primitive, or with `Task(executorPreference:
Ambient.current.taskExecutor)`), Dispatch, real I/O and real clocks. Work
arriving from there is waited for, but its timing is not seeded, so such a
run may not replay exactly; the fingerprint says when it did not, and the
run's report (and a test issue, unless `allowEscapes: true`) says that it
happened. A job
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
  run in parallel. `scripts/check.sh` holds Swift Testing's parallelization
  width to the core count: left unbounded, every test of a bundle starts at
  once, and on a small runner the real-time waits of tests over their own
  work are starved by the crowd.
- **No real sleeps as synchronisation.** Tests wait on clocks, gates and
  results.

## Planned

- **A task ledger and `assertQuiescent()`.** Every Stoic-owned task
  registered with its label and owner; a test's teardown asserts nothing is
  left running, no sleeper is pending, no scope is open and no work is
  abandoned — leaks become test failures that name their owner.
- **Adaptive horizons.** PCT guesses the run's length from the seed; a
  `simulate(seeds:)` that learns it from the first passing runs would find
  more with the same seeds, at the price of a replay recipe that names the
  horizon too.
- **More fault points.** Store writes torn or failing under simulation
  (the simulated file system already can), and a policy that targets the
  sites a failing seed hit, to shrink it.
- **Smarter scheduling.** Uniform choice finds shallow bugs fast; PCT-style
  priority schedules find deep ones with known probability. And shrinking:
  replay a failing seed with fewer preemptions until the minimal ordering
  remains.
- **Generated test skeletons** from the failure-mode tables, for a new
  contract.
- **Random streams split along the task tree.** A seeded `RandomSource`
  derives a stream from the seed and the call site, so every call through
  one `retry` site draws the same jitter, as does every supervisor (whose
  backoff draws at a site inside Stoic): a simulation of a hundred clients
  retrying together cannot show whether jitter spreads them, because it
  does not. And `IdempotencyKey.random` and span ids take a discriminator
  from a counter all tasks share, so which task draws which value depends
  on interleaving. The fix is to split the stream with the task tree, as
  JAX splits keys: every Stoic-started child takes its parent's stream and
  a deterministic child index, and a draw comes from the current task's
  stream, never from a site and a shared counter.
