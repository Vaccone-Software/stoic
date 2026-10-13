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
    public let span: SpanContext?         // the span it happened in (below)
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

## Spans

A span is a named, timed stretch of work with a parent: "this sync took
four seconds, of which the third retry's request took three". Stoic's events
say what was decided; a span says what it was decided *during*. Spans are
built on events and need no machinery beyond them.

```swift
public func withSpan<R, Failure: Error>(
    _ name: String, _ attributes: [Event.Field] = [],
    operation: () async throws(Failure) -> R) async throws(Failure) -> R
public struct Span { name, context, startedAt; static var current: Span? }  // task-local
public struct SpanContext { traceID, id, parentID: SpanID? }
public enum SpanStatus { ok, error, cancelled }
```

- **Two events.** `span.started` and `span.ended`, both `debug`. Both carry
  `span`, `trace`, `parent` (absent on a root), `name` and the attributes;
  `span.ended` adds `duration`, `status` and, for `error`, `error`. Ids,
  name and status are public; attributes keep their own privacy. The keys
  `span`, `trace`, `parent`, `name`, `duration`, `status` and `error` are the
  span's. The trace id is the root span's id.
- **Duration is measured on the ambient clock**, the same clock deadlines
  and retries use, so under a `TestClock` a span lasts exactly as long as the
  test advanced it. Ids come from the ambient `RandomSource`, so a seeded
  test sees the same ids every run.
- **The current span is a task-local** (`Span.current`). It reaches child
  tasks, `async let`, `Task {}` and the forks of `withTaskScope`; it does not
  reach `Task.detached`, which inherits nothing and starts a new trace.
- **Every event carries its span.** `Event.span` is the span current where
  the event was created, so a retry's `retry.attempt_failed` can be filed
  under the request it belonged to. `nil` outside a span.
- **Errors are status; cancellation is not an error.** A thrown error is
  `error` and is rethrown unchanged. A `CancellationError`, a `Report` of
  one, or a policy's `cancelled` rejection is `cancelled`, with no `error`
  field: nobody is paged because a user left the screen.
- **Free when off.** Spans are `debug` events. When the ambient
  instrumentation drops debug events (the default `OSLogInstrumentation`,
  `NoInstrumentation`), `withSpan` asks once and runs the operation: no id
  is drawn, no task-local bound, no event built.
- **Not a tracing client.** Spans live in one process and have no
  propagation format, sampling or export. `StoicObservability` maps them to
  swift-log metadata and swift-metrics timers (below); a swift-distributed-tracing
  bridge is a sink away.

| What happens if…                                          | Behaviour                                                                                              |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| no sink wants debug events                                | The operation runs; no ids are drawn, nothing is recorded, `Span.current` stays `nil`                  |
| a span is opened inside another                           | Its `parent` is the outer span's id and its `trace` the same                                           |
| a Stoic scope forks work inside a span                    | The fork's spans are children of that span                                                             |
| the clock is a test clock                                 | `duration` is exactly the virtual time the test advanced                                               |
| the operation throws                                      | `span.ended` has status `error` and the error; the error is rethrown unchanged                         |
| the operation is cancelled                                | `span.ended` has status `cancelled` and no `error` field                                               |
| an event is recorded inside a span                        | `Event.span` is that span's context                                                                    |

**Adapters.** `SwiftLogInstrumentation` writes `span`, `trace` and `parent`
into the metadata of every event recorded inside a span, so a log line is
filed under its operation; `span.started` and `span.ended` are ordinary
messages whose metadata holds the name, attributes, status and duration.
`SwiftMetricsInstrumentation` records each `span.ended` into a `Timer`
(`stoic_span_duration`, dimensions `name` and `status`), so request latency
and failure rate by span name need no per-call wiring. Span names are metric
dimensions: keep them low-cardinality.

## Golden traces (`StoicTesting`)

`events.trace()` renders the recorded decisions one per line — level, name,
label, fields, private values as `<private>`, debug events left out — and
`expectTrace(events, """…""")` compares them with a golden copy, showing
the first differing line and the whole actual trace on a mismatch. A result
says the scenario ended well; a trace says it got there as intended: two
attempts, not five; one breaker trip; nothing abandoned. On the test clock
with a fixed seed, traces are exact, durations included.

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

- An adapter to swift-distributed-tracing (events as span events; retries
  and deadlines as span attributes), as a package trait.
