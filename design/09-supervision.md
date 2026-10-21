# 09 · Supervision

Long-lived work fails. A sync engine loses its connection, an event tap
gets disabled by the system, a model server crashes on a bad input. The
hand-rolled answers — a watchdog timer that pings and aborts, a `while true
{ do { … } catch { sleep } }` loop — restart too eagerly or not at all, fire
during a slow launch or right after the Mac wakes, and turn a persistent
fault into a crash loop. Supervision is the discipline for this, and Erlang
has had the specification right for thirty years.

## Origin

- **Erlang/OTP supervisors.** Restart strategies (`one_for_one`,
  `one_for_all`, `rest_for_one`), restart types (`permanent`, `transient`,
  `temporary`), an intensity window that escalates when restarts are not
  helping, ordered start and reverse-ordered shutdown with per-child
  timeouts.
- **Akka.** Backoff with randomisation between restarts.
- **ServiceLifecycle.** A ladder from graceful shutdown to cancellation to
  giving up, and no restart option at all — the gap this fills.

## API

```swift
public final class Supervisor: Sendable {
    public init(label: String, strategy: Strategy = .oneForOne, intensity: Intensity = .standard,
                backoff: Schedule = .exponential(base: .milliseconds(500)).capped(at: .seconds(30)),
                resetAfter: Duration = .seconds(30), @ChildrenBuilder children: () -> [Child])
    public func run() async throws            // SupervisorEscalation, or CancellationError
    public func events() -> AsyncStream<SupervisorEvent>   // one stream per call
}
public struct Child { init(_ label: String, restart: RestartPolicy = .permanent, heartbeat: HeartbeatPolicy? = nil,
                           shutdownTimeout: Duration = .seconds(5), run: @escaping @Sendable (Heartbeat) async throws -> Void) }
public enum RestartPolicy { case permanent, transient, temporary }
public struct HeartbeatPolicy { init(interval: Duration, misses: Int = 3, grace: Duration = .seconds(30)) }
public final class Heartbeat { public func beat() }
```

## Semantics

**One loop decides.** Children, heartbeat monitors and restart timers send
signals to a single loop that owns all state. Every child run has a
generation; a signal from a generation that has been stopped or replaced is
stale and ignored, so a child stopped by the supervisor can never be
mistaken for one that crashed.

**Restarts.** `permanent` children restart whenever they stop; `transient`
only when they throw; `temporary` never. When every child has finished for
good, `run()` returns. A child that ends with a cancellation the supervisor
did not ask for — a session invalidated elsewhere — threw: it stopped when
it should not have, so it is a failure, and `supervisor.child_exited` says
so (`cause: cancelled_from_outside`) rather than reporting an ordinary
error. The supervisor's own stops, which cancel a child on purpose, are
never counted.

**Strategies.** `oneForOne` restarts the stopped child. `oneForAll` stops the
others newest first and restarts all in order. `restForOne` does the same
for the stopped child and those started after it.

**Intensity.** More than `maxRestarts` within `window` (five a minute by
default) means restarting is not helping: every child is stopped and `run()`
throws `SupervisorEscalation` with the child and its last error, for the
next level up — a parent supervisor, a service graph, or the process. A
crash (a trap) cannot be caught in-process; that level is the operating
system restarting the process, and is configured there (launchd's
`KeepAlive`, the app being relaunched).

**Overlapping restarts.** A newer restart decision supersedes any restart
already pending for the children it covers, and a child never runs two
instances: so a second failure during a group's backoff cannot start members
out of order or twice. A child that finished for good (a transient that
returned, a temporary) stays finished when its group restarts.

**Children own their time.** A child runs without the deadline of whoever
called `run()`: it lives as long as the supervisor keeps it. Restart delays
are counted from the decision and heartbeat checks fall on fixed instants
from the child's start, so neither a timer's own scheduling delay nor drift
across intervals stretches them. The exception is a check that runs more
than a whole interval late (see Heartbeats): that is a gap, and the instants
are counted afresh from it.

**Backoff.** Each child waits on the supervisor's schedule before
restarting (jittered exponential by default, capped at 30 s); a child that
ran for `resetAfter` without stopping starts its backoff over. A struggling
device stretches each delay by `SystemConditions.backoffFactor` (up to eight
times), and the schedule's cap is the last word: a schedule capped at 30 s
never waits longer than that, whatever the device, while an uncapped delay
stretches. A schedule that ends means restarting should stop: the supervisor
escalates. The schedule's elapsed time (`upTo(elapsed:)`) counts from the
first failure of the current streak, and starts over with the backoff.

**Heartbeats.** A child with a `HeartbeatPolicy` calls `beat()` while it
makes progress. Silence for `misses` consecutive intervals (three by
default — one slow moment is not a hang) means hung: the child is stopped
and restarted like a failure. Heartbeats use the liveness clock, which
stops while the machine sleeps, and are not checked during `grace` after a
start, for slow launches. Both rules exist because watchdogs that ignored
them have turned slow launches and wake-from-sleep into crash loops.

**Gaps.** The liveness clock stops while the machine sleeps, but not while
the process alone is frozen: `kill -STOP`, a debugger, iOS suspending an
app in the background. On resume, every check that came due meanwhile would
run at once, back to back, before the child gets to run, and a healthy
child would be counted silent `misses` times. So a check that wakes more
than one interval after its instant is a gap, not evidence: it counts no
miss, the misses so far are forgotten, and the checks start again from that
moment, so the child has at least one full interval to beat. A check that
is late by less than an interval is judged as usual and the next one stays
on its fixed instant, so the monitor's own scheduling delays neither
stretch the wait nor accumulate.

**Stopping.** Newest first. Each child is cancelled with cause
`supervisorStopped` (`childHung` when it is stopped as hung, so its cleanup
can tell the two apart) and given its `shutdownTimeout`; one that does not stop
is abandoned and reported (`supervisor.child_abandoned`) so shutdown always
finishes.

## Failure modes

| What happens if…                                     | Behaviour                                                                         |
| ---------------------------------------------------- | --------------------------------------------------------------------------------- |
| a permanent child throws                             | Restarted after its backoff                                                       |
| a transient child returns                            | Done; not restarted                                                               |
| a temporary child throws                             | Done; reported                                                                    |
| restarts exceed the intensity                        | All children stopped; `SupervisorEscalation` thrown                               |
| two observers watch the supervisor                   | Each `events()` stream sees every event                                           |
| the backoff schedule ends                            | All children stopped; `SupervisorEscalation` thrown                               |
| a child stops beating                                | After `misses` intervals (past `grace`): stopped and restarted                    |
| the Mac sleeps                                       | The liveness clock stops; no false hang                                           |
| the process is suspended for longer than an interval | A gap, not misses: checks restart from the resume; the child gets a full interval |
| a child is cancelled by something else               | A failure, restarted; `child_exited` says `cancelled_from_outside`                |
| the supervisor's task is cancelled                   | Children stopped newest first; `CancellationError`                                |
| a child ignores cancellation on shutdown             | Abandoned after `shutdownTimeout`; reported                                       |
| a child ran long and then failed                     | Its backoff starts over                                                           |
| the device is hot, saving power or short of memory   | Restart delays stretch with its backoff factor, never past the schedule's cap     |

## Events

`supervisor.child_started`, `supervisor.child_exited` (failed or not, with
the error), `supervisor.child_restarting` (delay), `supervisor.child_hung`,
`supervisor.child_abandoned`, `supervisor.escalated`, `supervisor.stopped`;
also published on `events()` for a UI or a parent. Each call makes a stream
of its own, so every subscriber sees every event from when it subscribed
(the newest 256 buffered); a single shared stream would deal each event to
one of its consumers. Every stream finishes when `run()` ends.

## Testing

Each row above, on the virtual clock: restart after backoff, transient and
temporary completion, escalation, both multi-child strategies, a silent child
detected and a beating one left alone, a suspension of many intervals (a
clock that jumps, as a frozen process sees it) that hangs nothing while a
check a little late still counts, cancellation order and causes,
abandonment, and a capped backoff that device pressure does not stretch past
its cap. 300 repetitions are clean.

## Planned

- `Supervisor` as a ServiceLifecycle `Service` (trait), and as a child of a
  parent supervisor without ceremony.
- "Significant" children whose completion stops the supervisor (OTP's
  `auto_shutdown`).
- A crash-loop marker for the process level: unclean launches counted
  across restarts, with a safe mode after too many (design/15, planned).
