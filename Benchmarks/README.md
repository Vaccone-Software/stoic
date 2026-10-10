# Benchmarks

Micro-benchmarks of Stoic's hot paths. Run in release:

```sh
cd Benchmarks && swift run -c release
```

Best of three rounds on an Apple silicon Mac, Swift 6.4, with events going
nowhere (`NoInstrumentation`). Numbers are for spotting regressions and
orders of magnitude, not for comparing machines.

| Path                                       | Cost      | Notes |
| ------------------------------------------ | --------- | ----- |
| `Ambient.current`                          | ~50 ns    | a task-local read and a copy of the context |
| `AsyncSemaphore.withPermit`, uncontended   | ~350 ns   | release builds; debug builds add reentrancy tracking |
| `CircuitBreaker.execute`, closed, success  | ~700 ns   | window bookkeeping; the per-call debug event is skipped when nothing records it |
| `retry`, first attempt succeeds            | ~750 ns   | the nesting marker is most of it; the schedule is built only on a failure |
| `StateMachine.send`                        | ~900 ns   | |
| Schedule step                              | ~1.1 µs   | paid once per *retry*, beside a sleep of milliseconds |
| `withScope` with one finalizer             | ~21 µs    | each finalizer runs in its own task so a hung one can be abandoned |
| `withTimeout`, completing at once          | ~32 µs    | a task group with two children: the price of cancelling work without cancelling the caller |

**What the numbers say.** Everything that sits on a per-call path costs
less than a microsecond. The two structural primitives cost tens of
microseconds because they create tasks, which is what their guarantees
require; they belong around I/O, not inside tight loops.

**Found and fixed by measuring.** Semaphore reentrancy tracking (a
task-local push per permit) is now debug-only; instrumentation can say a
level is disabled, so debug events on hot paths are not built for nothing;
per-call-site budget keys no longer build a string on every retry; a
retry's schedule is built lazily; transition records keep the event value
instead of formatting it.
