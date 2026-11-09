# 25 · XPC services

An app that moves its riskiest work into a helper process — a language model
that can take gigabytes and crash, a clipboard read that can hang on another
app's lazy data — trades one failure for a set of new ones. The helper can be
killed by the app, by the system or by a crash at any moment. It can wedge
mid-request. It can still be exiting when the next request arrives, and that
request then reaches the process that is leaving. It can be a newer build than
the app talking to it, because the app was updated on disk while it ran. By
hand, each of those is a generation counter, a continuation resumed from two
callbacks, a flag, and a sleep before `exit`; and each is found by CI, under
load, by luck. `StoicXPC` is the one way to call a helper process: the
service's lifecycle is explicit, every wait is bounded, every loss is one event,
and what a lost call may have done is known.

## The ideal scenario

> The editor asks a language model that runs in another process. That process
> can be killed by the app, by the system or by a crash at any moment. It can
> wedge mid-generation, or still be exiting when the next request arrives. The
> app never hangs on it, never sends to a process that is exiting, and never
> talks to a build it was not built with. Every one of those decisions is made
> once, by the framework, and reported.

```swift
// The module both the app and the service import.
extension Backend {
    static let models = Backend.compute("models")           // one generation at a time
    static let modelsControl = Backend.system("models.control")
}
enum ModelsAPI {
    static let respond = XPCMethod<Generate, String, ModelsFailure>(
        Backend.models.notRepeatable("respond", length: .long), ifStuck: .endService(after: .seconds(20)))
    static let stats = XPCMethod<Empty, ModelsStats, Never>(Backend.modelsControl.readOnly("stats"))
}

// The app.
let models = XPCPeer(service: "com.example.app.models", build: Build.id)
let text = try await models.call(ModelsAPI.respond, Generate(prompt))
let stats = try await models.call(ModelsAPI.stats, Empty(), ifRunning: true)   // never starts the service

// The service's main.swift.
let host = XPCHost(build: Build.id)
host.handle(ModelsAPI.respond) { request, _ throws(ModelsFailure) in try await engine.respond(request) }
host.handle(ModelsAPI.stats) { _, _ in engine.stats }
host.run()
```

## Origin

- **Lodestar 0.54.21 and 0.54.22**, the pilot. `ModelsClient` and `ModelsService`
  are this contract written by hand: `Once`, `Request`, `Answer`, an `epoch`
  compared in callbacks, a table of early cancels capped at 64, an idle exit
  driven by a generation counter, `wedgedAfter` and `exit(1)` in the clipboard
  reader. Two of their bugs are rows below: `41f2de7` (a reload reached the
  process that was exiting) and `6a7ce61` (the loss of a run was handled twice,
  once from each callback).
- **Apple DTS (Quinn)**: XPC is the preferred inter-process mechanism on Apple
  platforms; Mach messaging directly is discouraged; sockets are for crossing
  namespaces or talking to non-Apple code; `Subprocess` is for one-shot tools;
  distributed actors ship no transport. One transport, then, and its names say
  so: `XPCPeer`, not `Peer`.
- **A spike on macOS 27.2**, measured, not read (the numbers are observations,
  and the contract depends on none of them being exact):
  - An `XPCSession` is dead for good once its service exits; `NSXPCConnection`
    relaunches the service behind the same object. One session is one run of
    the service, which is the model here.
  - A new session made right after asking the service to exit reaches the
    exiting process, which answers. The asked session's cancellation handler
    runs within a millisecond of the process's real exit: the "gone" signal.
  - `cancel()` does not fail a pending reply (the reply still arrives, seconds
    later): the caller needs its own deadline.
  - Releasing a session that was never cancelled traps the client.
  - launchd delays the next start of a service that lived under ten seconds
    until ten seconds after its launch, silently; one that lived longer
    restarts in 15–30 ms.
  - A handler that lets a reply-expecting message go without replying tears
    the client's session down while the process lives.
  - The listener's queue is shared by every session: a blocked handler stalls
    all of them. Replying later, from a task, frees it.
  - Messages and replies are delivered in order, both ways. The order of a
    reply's failure and the session's cancellation handler was stable at idle,
    and is documented nowhere.
  - Each client process has its own instance of a bundled service, gone within
    100 ms of the client exiting.
  - The app bundle replaced on disk while the old app runs: the services it
    starts next are the new build.
  - A sandboxed app cannot signal its own service (`EPERM`, even signal 0), and
    cancelling the service's only session does not end it. Only the service
    can end itself.
  - Swift 6 refuses every way of carrying an `XPCReceivedMessage` off the
    handler (it is not `Sendable`, and the handler's parameter is not
    `sending`): replying later needs one audited wrapper.
  - A `[Float]` of 480 000 samples costs 518 ms through XPC's `Codable`
    encoding and 0.37 ms as `Data`.

## Rules

1. **Bundled services only**, in `Contents/XPCServices`, found by name. launchd
   lets only the containing app connect, so no peer requirement is needed. A
   Mach service (a launch agent, `SMAppService`) waits for a use case.
2. **One `XPCPeer` per service per process.** The service is one process per
   client process, and the peer is its single owner: two peers would share a
   process each thinks it owns. A second declaration is reported at error level.
3. **The build is part of the handshake.** Both sides are given the same
   compiled-in identifier (`Build.id`, from a module both import); a different
   one is refused, never decoded.
4. **Bulk data crosses as `Data`.** XPC's `Codable` encoding of a large array of
   numbers is three orders of magnitude slower; a `Data` field goes out of line.

## API

```swift
public struct XPCMethod<Request: Codable & Sendable, Reply: Codable & Sendable, Failure: Error & Codable & Sendable>: Sendable {
    public init(_ operation: Backend.Operation, ifStuck: XPCStuck = .wait)
    public let operation: Backend.Operation
    public let ifStuck: XPCStuck
    public var name: String                         // "<backend>.<operation>": the wire name
}
public enum XPCStuck: Sendable, Hashable { case wait, endService(after: Duration) }
public struct Empty: Codable, Sendable, Hashable { public init() }     // XPCEmpty

public final class XPCPeer: Sendable {
    public init(service: String, build: String, policy: XPCPeerPolicy = .standard, transport: (any XPCTransport)? = nil)
    public func call<Request, Reply, Failure>(_ method: XPCMethod<Request, Reply, Failure>, _ request: Request,
                                              ifRunning: Bool = false, idempotencyKey: IdempotencyKey? = nil)
        async throws(OperationError<XPCCallError<Failure>>) -> Reply
    public var run: XPCRun? { get }                 // the live run, if any
    public func end(reason: String) async -> XPCEndResult
    public func shutdown()
}
public struct XPCPeerPolicy: Sendable { handshakeTimeout, endGrace, killGrace; static let standard }
public struct XPCRun: Sendable, Hashable { number, pid, build }
public enum XPCEndResult: Sendable, Hashable { case notRunning, exited, killed, wedged }
public enum XPCCallError<Failure>: Error, Retryable {
    case failed(Failure)                  // the handler's own answer
    case lost(afterSending: Bool)         // the run ended
    case cancelled(afterSending: Bool)    // the caller left, or an attempt timed out
    case notRunning                       // `ifRunning`, and no live run
    case buildMismatch(expected: String, found: String)
    case unavailable(String)              // no such service, shut down, or wedged
    case protocolViolation(String)        // an unknown method, a message that does not decode
}

public final class XPCHost: Sendable {
    public init(build: String, policy: XPCHostPolicy = .standard)
    public func handle<Request, Reply, Failure>(_ method: XPCMethod<Request, Reply, Failure>,
        _ handler: @escaping @Sendable (Request, XPCRequestContext) async throws(Failure) -> Reply)
    public func hold(_ reason: String)    // keeps an idle service alive: a loaded model
    public func release(_ reason: String)
    public func run(service: String? = nil) -> Never
}
public struct XPCHostPolicy: Sendable { idleExit: Duration?, watchdogGrace, exit: @Sendable (Int32) -> Never; static let standard }
public struct XPCRequestContext: Sendable { id, method, idempotencyKey, run }

public protocol XPCTransport: Sendable { … }     // the seam: XPCSession, or the simulation
public final class XPCSimulatedService: XPCTransport { init(pid:, makeHost:); crash(…), runs, exitLag, permitsKill }
```

## Semantics

**A run.** The peer's state is one of: no run; _starting_ (a session is open and
the handshake in flight); _running_; _ending_ (the run was asked to exit and the
peer waits for it to be gone); _wedged_ (it would not exit); _mismatched_; _shut
down_. A run begins with a session and a handshake — the client's build, and
the service's build and pid in reply — and ends with the first sign that its
process is gone: the session's cancellation handler, or a reply that failed
because the connection did. Whichever comes first ends the run once; the other
is ignored. Every call still waiting on that run fails at once with
`.lost(afterSending: true)`. A peer opens a new session only when the run
before it is gone, so a request can never reach a process that is leaving.

**Starting.** The first call with no run starts one; calls that arrive while it
starts wait for the same handshake (one session, one hello). The handshake runs
on the peer's behalf, not the first caller's: it is bounded by
`handshakeTimeout` (20 s: launchd's relaunch delay is ten), not by the deadline
of whoever happened to start it, and each waiter is bounded by its own. A
service that is not in the bundle fails `.unavailable`. A run whose build is
not the peer's is refused: the session is ended, `xpc.build_mismatch` is
reported at error level, and every call fails `.buildMismatch` until the app
restarts. A run that answers "exiting" is the old process lingering: the peer
treats it as ending and waits for it to be gone.

**A call** runs through the method's operation's `perform` (design/22): the
deadline, retries by the declared repeat safety, the breaker, admission by the
backend's capacity. Each attempt takes the live run (starting one if none),
sends the request with the time left before the deadline, and waits for the
reply or its own cancellation, whichever is first — `cancel` does not fail a
pending reply, so the attempt does not wait for XPC to. A failure before the
request was sent is `neverReachedBackend` (so even a `.notRepeatable` call is
repeated); a run lost after the send is `.lost(afterSending: true)`, outcome
`.unknown`, repeated only when the declaration allows. The handler's own
`Failure` arrives typed, as the backend's permanent answer (`.executed`), and is
retried only if the failure is `Retryable` and says so. A `.keyed` method's
attempts send `attempt.idempotencyKey`; the handler reads it from its context.
`ifRunning: true` fails `.notRunning` at once, starting nothing, unless a run is
live: a status read that must not launch the model.

**Cancellation.** A caller cancelled (or an attempt timed out) after its request
was sent returns at once; the peer then sends a cancel for that request on the
same session, and the service cancels the handler's task. Delivery is in order,
so a cancel never arrives before its request, and the service needs no table of
early cancels: a cancel for an id it does not hold is reported at debug level
and dropped. The handler's reply, when it comes, is dropped (`xpc.late_reply`).

**Stuck.** `ifStuck: .endService(after: d)` declares that a request still
unanswered `d` after its caller left means the service is wedged. The verdict is
measured on the liveness clock, so a Mac asleep is not a wedge. The peer then
ends the run (below), and reports `xpc.call_stuck`. An end the peer decides is
not the backend failing: it is not counted against the breaker.

**Ending.** `end(reason:)` moves the run to _ending_, asks the service to exit,
and waits up to `endGrace` (2 s) for it to be gone. Calls made meanwhile wait
for it too, within their own deadlines, and then reach a new run. A run still
there after the grace is killed — `SIGKILL`, to the pid from its handshake, only
after checking that the process at that pid is an executable in this app's
`Contents/XPCServices` — and given `killGrace` (1 s). A sandboxed app may not
signal its service; then, or if the kill does not end it, the run is _wedged_:
`xpc.run_wedged` at error level, and every call fails `.unavailable` at once
until the process goes (the service's own watchdog, below, is what ends it).

**The relaunch delay.** When a run that lived under ten seconds is gone, the next
start is reported as `xpc.relaunch_throttled` with the expected wait. Nothing is
failed for it: the deadline still decides.

**The host** listens on its bundle's service name, one state per process. Each
message is decoded on the listener's queue (cheap) and every handler runs in its
own task, so a slow handler holds no other session up. Each request is answered
exactly once — the reply, the handler's failure, "cancelled", or a refusal — and
a message is never let go unanswered (that would end the client's session). A
request carries its budget: the handler runs under that deadline, cooperatively.
**The watchdog** is a timer on its own queue, off the cooperative pool and off
the listener's queue, on the liveness clock: a handler still running
`watchdogGrace` (10 s) past its budget has ignored cancellation, and the process
exits (`xpc.watchdog_exit`, error level) so the next call gets a fresh one. That
is the only way a wedged service ends in a sandbox.

**Idle exit.** With `idleExit` set, a service with nothing in flight and nothing
held (`hold`/`release`, by reason: a loaded model) for that long exits
(`xpc.idle_exit`). From the moment it decides to exit, every request is refused
"exiting" — never executed — so the client resends it to the next run.

**Exit** happens on a queue no request ever holds, through `policy.exit`
(`_exit` by default: a model's destructors need not run on the way out). A
client session that ends cancels that session's handlers.

## Failure modes

| What happens if…                                                 | Then                                                                                     |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| the service is not in the app's bundle                           | `.unavailable`, not repeated, `neverReachedBackend`                                      |
| the run is lost before a request is sent                         | the request is sent to a new run: `neverReachedBackend`                                  |
| the run is lost after an idempotent request is sent              | the request is resent once, to a new run                                                 |
| the run is lost after a not-repeatable request is sent           | it fails `.lost(afterSending: true)`, outcome `.unknown`, not resent                     |
| the reply's failure and the session's end arrive in either order | one loss: one `xpc.run_lost`, every waiting call failed once                             |
| a call is made while an ended run is still exiting               | it waits for the run to be gone, then reaches a new run                                  |
| a request reaches a run that has decided to exit                 | it is refused, never executed, and resent to the next run                                |
| many calls arrive while no run is live                           | one session, one handshake                                                               |
| the caller's deadline is shorter than the handshake              | that caller fails at its deadline; the handshake goes on for the others                  |
| the caller is cancelled before its request is sent               | nothing is sent                                                                          |
| the caller is cancelled after its request is sent                | it returns at once; the service cancels the handler                                      |
| a reply arrives after its caller left                            | it is dropped and reported                                                               |
| a cancel arrives for a request the service no longer holds       | it is dropped and reported at debug level                                                |
| a cancelled request stays unanswered past `ifStuck`              | the run is ended and `xpc.call_stuck` reported; the breaker does not count it            |
| the run does not exit when asked                                 | it is killed, after the pid is checked to be this app's service                          |
| the run cannot be killed (a sandbox) and does not exit           | `xpc.run_wedged`; calls fail `.unavailable` at once until it goes, then a new run starts |
| the service is another build                                     | `xpc.build_mismatch`; every call fails `.buildMismatch`, not repeated                    |
| the client is another build                                      | the service refuses its requests                                                         |
| a handler throws its declared failure                            | the caller gets it, typed: `.failed`, outcome `.executed`, not repeated                  |
| a handler ignores cancellation past its budget and the grace     | the service exits (`xpc.watchdog_exit`); the client sees the run lost                    |
| the service is idle and holds nothing for the idle period        | it exits (`xpc.idle_exit`); the next call starts a new run                               |
| a request arrives during the idle period                         | the idle exit is put off                                                                 |
| the service holds something                                      | it does not idle-exit until released                                                     |
| a request names a method the service does not handle             | `.protocolViolation`, not repeated                                                       |
| a request does not decode as the method's type                   | `.protocolViolation`, not repeated                                                       |
| a client's session ends with handlers running                    | those handlers are cancelled                                                             |
| `ifRunning` is asked with no live run                            | `.notRunning` at once; nothing is started                                                |
| the run before lived under ten seconds                           | the next start is reported as `xpc.relaunch_throttled`                                   |
| a second peer is made for the same service                       | `xpc.peer_duplicate` at error level                                                      |
| the peer is shut down with calls waiting                         | they fail `.unavailable`; the session is cancelled, never released live                  |

## Events

All in `EventCatalog`, labelled with the service name (client) or the method
(host). They carry pids, builds, run numbers, method names, durations and
counts; never a request or a reply.

| Event                    | Level   | Meaning                                                              |
| ------------------------ | ------- | -------------------------------------------------------------------- |
| `xpc.run_started`        | info    | a run answered the handshake: run, pid, build, how long it took      |
| `xpc.run_lost`           | warning | a run ended without being asked: run, pid, lifetime, calls in flight |
| `xpc.run_ended`          | info    | a run ended as asked: run, reason, how long the exit took            |
| `xpc.run_wedged`         | error   | a run would not exit: calls are refused until it does                |
| `xpc.end_escalated`      | warning | a run outlived its grace; whether the kill was permitted             |
| `xpc.build_mismatch`     | error   | the other side is another build: expected, found                     |
| `xpc.relaunch_throttled` | notice  | the run before lived under ten seconds; the expected wait            |
| `xpc.call_stuck`         | warning | a cancelled request stayed unanswered past `ifStuck`                 |
| `xpc.late_reply`         | debug   | a reply arrived after its caller left                                |
| `xpc.handshake_failed`   | warning | a run could not be started: why                                      |
| `xpc.peer_duplicate`     | error   | a second peer for one service                                        |
| `xpc.host_started`       | info    | the service listens: build, pid                                      |
| `xpc.request_refused`    | notice  | unknown method, undecodable, exiting, or another build               |
| `xpc.cancel_unknown`     | debug   | a cancel for a request no longer held                                |
| `xpc.host_exiting`       | info    | the service exits as asked                                           |
| `xpc.idle_exit`          | info    | the service exits, idle                                              |
| `xpc.watchdog_exit`      | error   | a handler ignored cancellation; the service exits                    |

## Testing

- Every row above on `XPCSimulatedService`: the real `XPCHost` and its handlers
  in-process, a run that can crash (replies or end first, or a fault point
  between), linger while exiting (`exitLag`), refuse a kill, or wedge; on a
  `TestClock`.
- `scripts/xpc-integration.sh`: the same peer and host as real processes, in an
  app bundle assembled from SwiftPM's products and signed ad hoc — the
  handshake, a crash, a requested end, the watchdog, a cancelled call. It
  signals nothing but the service it started, through the same pid check.

## Not built

- `PeerResident`: state kept in the service (a loaded model) and loaded again
  on demand when its run is lost. It waits for the Lodestar pilot to give it
  its shape.
- Mach services and `SMAppService` agents, with peer requirements.
- Large payloads out of band (shared memory, file descriptors, `IOSurface`).
- iOS: the system's session and listener initializers are unavailable there;
  the library compiles to nothing on platforms other than macOS.
