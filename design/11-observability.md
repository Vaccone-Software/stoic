# 11 · Observability

A silent decision is a bug. Every time a Stoic primitive decides something
the app's author did not explicitly write — retry or give up, drop an
element, abandon a finalizer, restart a child, open a circuit — it reports
the decision as a structured event. When a user says "it hung for a minute
and then worked", the events say which retry slept, which deadline passed,
and which child restarted.

## API

```swift
public struct Event: Sendable {
    public let name: EventName            // stable: "retry.exhausted"
    public let level: Level               // debug, info, notice, warning, error
    public let label: String?             // which instance decided
    public let fields: [Field]            // key, value, privacy
    public let fileID: String; public let line: UInt
}
public protocol Instrumentation: Sendable { func record(_ event: Event) }
public struct OSLogInstrumentation: Instrumentation   // the default; subsystem "stoic"
public struct NoInstrumentation, CompositeInstrumentation
public enum EventCatalog { static let entries: [Entry] }  // every name, level and meaning
```

## Semantics

**Names are API.** Every name lives in `EventCatalog` with its usual level
and its meaning. A test scans the sources: a literal event name missing from
the catalog, or a catalogued name nothing emits, fails the build's tests.
Names are never renamed or removed in a minor release, so dashboards,
queries and alerts built on them keep working.

**Recording never blocks a decision.** `record` is synchronous and must
not block; Stoic never awaits a sink, and records events outside its locks,
so a slow or reentrant sink can cost latency but cannot deadlock a
primitive.

**Privacy by default.** Numbers, durations and booleans are public; strings
and error descriptions are private unless a primitive marks them public
(names, labels, enum-like values). The OSLog sink maps this onto OSLog's
own privacy, so private fields are redacted in collected logs. `Secret`
values are always redacted.

**Where events go.** `Ambient.instrumentation`: OSLog by default, a
recording sink in tests (`withTestAmbient`, `@Test(.stoic)`), and any
composition of sinks an app installs.

## The catalog

| Area           | Events                                                                                                                                                                                                                   |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Deadlines      | `deadline.expired`                                                                                                                                                                                                       |
| Retry          | `retry.attempt_failed`, `retry.succeeded`, `retry.exhausted`, `retry.permanent`, `retry.defect`, `retry.nested`, `retry.cancelled`, `retry.deadline_skip`, `retry.budget_exhausted`, `retry.after_capped`; `recur.ended` |
| Concurrency    | `slot.superseded`, `slot.superseded_late`, `race.won`, `race.all_failed`, `semaphore.rejected`, `semaphore.reentrant`, `singleflight.joined`, `singleflight.abandoned`, `channel.dropped`                                |
| Scopes         | `scope.finalizer_failed`, `scope.finalizer_slow`, `scope.finalizer_abandoned`, `scope.child_failed`, `scope.fork_after_exit`                                                                                             |
| State machines | `statemachine.transition`, `statemachine.invalid`, `statemachine.stale_event`                                                                                                                                            |
| Supervision    | `supervisor.child_started`, `supervisor.child_exited`, `supervisor.child_restarting`, `supervisor.child_hung`, `supervisor.child_abandoned`, `supervisor.escalated`, `supervisor.stopped`                                |
| Services       | `service.started`                                                                                                                                                                                                        |

`EventCatalog.entries` is the authoritative list, with each event's level
and meaning.

## Flight recorder (`StoicStore`)

`FlightRecorder` is an `Instrumentation` that writes each event to a
fixed-size file as it happens, so the next launch can read what the
previous run was deciding when it died (`previousRun`), and whether it
ended on purpose (`markCleanExit()`). The in-memory ring (`EventRing`,
`Diagnostics.snapshot`) answers "what just happened" in this run; the
recorder answers it about the run that crashed.

- **Format.** A 32-byte header, then a circular region of records, each
  `length | crc32c | sequence | payload`, 8-byte aligned. Recovery scans
  every aligned offset and keeps records whose checksum holds, so neither a
  torn record nor old bytes the writer partly overwrote can be misread, and
  there is no index for a crash to leave inconsistent. Sequences continue
  across runs; run boundaries are marker records.
- **Durability.** One `pwrite` per event: the page cache outlives the
  process, so a crash, a kill or a watchdog termination loses nothing
  written. `flush()` (one full sync) makes everything so far survive power
  loss too.
- **Why not `mmap`.** It saves the system call, but a store to a mapped page
  the disk cannot back — a full disk, a copy-on-write block under a
  snapshot — kills the process with SIGBUS: the recorder would cause the
  crash it exists to explain. A failed write stops the recorder
  (`status`), and the app goes on. The file is allocated in full when
  created, so a full disk shows up then.
- **Privacy.** Private values are stored as `<private>` (an error keeps its
  public type) unless `recordPrivateValues` is set; strings are cut at 256
  bytes on a character boundary.
- **Tested** at every crash point of a run, under every way the simulated
  disk can lose unsynced data: recovery never misreads a record, never
  reorders, and keeps everything recorded before a `flush()`. Breaking the
  checksum check or the flush makes that test fail.

## Planned

- Adapters, as package traits: swift-log, swift-metrics (counters per event
  name, histograms for durations), swift-distributed-tracing (events as
  span events; retries and deadlines as span attributes).
- Golden-trace assertions in `StoicTesting`: a test asserts the sequence of
  decisions, not only the result.
