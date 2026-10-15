# Benchmarks

Micro-benchmarks of Stoic's hot paths. Run in release:

```sh
cd Benchmarks && swift run -c release                                     # report
cd Benchmarks && swift run -c release StoicBenchmarks --check allocations.json   # the gate
cd Benchmarks && swift run -c release StoicBenchmarks --record allocations.json  # ratchet down
```

Each path reports its best time of three rounds and its allocations per
call, counted by a malloc logging hook. **Allocations are the gate**
(`scripts/check.sh`): a path that allocates more than `allocations.json`
records, by more than half an allocation, fails the build, and one that
allocates less is reported so the record can be ratcheted down. Time is
reported, not gated: shared CI machines drift by more than any regression
worth catching, while allocation counts barely move.

Measured on an Apple silicon Mac, Swift 6.4, with events going nowhere
(`NoInstrumentation`). Numbers are for spotting regressions and orders of
magnitude, not for comparing machines.

| Path                                       | Cost      | Allocations | Notes |
| ------------------------------------------ | --------- | ----------- | ----- |
| `Ambient.current`                          | ~60 ns    | 0           | a task-local read and a copy of the context |
| `AsyncSemaphore.withPermit`, uncontended   | ~350 ns   | 0           | release builds; debug builds add reentrancy tracking |
| `CircuitBreaker.execute`, closed, success  | ~750 ns   | 1           | window bookkeeping; the per-call debug event is skipped when nothing records it |
| `retry`, first attempt succeeds            | ~850 ns   | 5           | the nesting marker is most of it; the schedule is built only on a failure |
| Schedule step                              | ~1.2 µs   | 3           | paid once per *retry*, beside a sleep of milliseconds |
| `StateMachine.send`                        | ~5.8 µs   | 6           | was ~0.9 µs when first measured: a regression the time-only harness never flagged, not yet investigated |
| `withScope` with one finalizer             | ~27 µs    | 33          | each finalizer runs in its own task so a hung one can be abandoned |
| `withTimeout`, completing at once          | ~38 µs    | 20          | a task group with two children: the price of cancelling work without cancelling the caller |

**What the numbers say.** Everything that sits on a per-call path costs
less than a microsecond, except `StateMachine.send` (above). The two structural primitives cost tens of
microseconds because they create tasks, which is what their guarantees
require; they belong around I/O, not inside tight loops.

**Found and fixed by measuring.** Semaphore reentrancy tracking (a
task-local push per permit) is now debug-only; instrumentation can say a
level is disabled, so debug events on hot paths are not built for nothing;
per-call-site budget keys no longer build a string on every retry; a
retry's schedule is built lazily; transition records keep the event value
instead of formatting it.
