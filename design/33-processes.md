# 33 · Child processes

An app that runs other programs (git, a build, a dev server, a language
model's command-line client held open across turns, a helper it ships)
inherits every way a process can go wrong, and `Foundation.Process` answers
none of them. The child starts what it likes, and a `terminate()` reaches
only the child: the shell dies and the `node` it started keeps the port. The
termination handler and the output arrive on different threads, so the exit
can be heard before the last line of output. A write to a child that stopped
reading blocks whoever wrote it, the main thread included, and a write to one
that ended raises `SIGPIPE`, which ends the app. Output read into memory as it
comes grows with whatever the child prints. And when the app crashes, its
children are adopted by launchd and run on: macOS has no way to say "end
this child when I end". `StoicProcess` is the one way to run a program:
every child in a process group of its own, its output read only as fast as it
is asked for, its input queued in order and bounded, its stop shielded and
bounded, no signal sent to a pid that may have been reused, and the children
a crash left behind found again at the next launch.

## The ideal scenario

> An editor keeps a language model's client running for each conversation,
> runs the project's build and its dev server, and asks git a dozen questions
> a minute. A conversation closed stops its client and every command the
> client started. A build that hangs is stopped at its deadline with the end
> of what it printed. The main thread hands the client a message and never
> waits for it to be read. The app crashes; on the next launch, the clients
> and the dev server the crashed run left behind are stopped before anything
> new starts.

```swift
// A program run to its end.
let status = try await ChildProcess.run(
    Command("/usr/bin/git", ["status", "--porcelain"], in: folder, environment: environment, errors: .mergeWithOutput),
    timeout: .seconds(60))
if status.timedOut { … } else if status.succeeded { use(status.outputText) }

// A program held open.
let ledger = ProcessLedger(directory: support + "/children")
await ledger.reapOrphans()                                 // once, at launch
let client = try ChildProcess.start(
    Command(claude, arguments, in: folder, environment: environment, input: .pipe),
    options: .init(label: "session", ledger: ledger))
try client.input!.send(message + "\n")                     // never blocks; ordered; bounded
for await lines in client.output!.lineBatches() { await deliver(lines) }   // one hop per read
let exit = try await client.waitForExit()                  // after the last line
await client.stop()                                        // SIGTERM to the group, SIGKILL after the grace
```

## Origin

- **Woodsmoke**, the pilot. Six ways of starting a program in one app: a
  `Process` with a readability handler and a 64 KB tail, a detached thread
  reading a session's output line by line, writes to its input on a serial
  queue under `try?`, a walk of `proc_listchildpids` before `SIGTERM` and an
  unstructured task for the `SIGKILL` that never ran when the app quit, a
  login shell's `readDataToEndOfFile` under `abandoningAfter` that left the
  shell running at its deadline, a supervisor hand-rolled with a generation
  counter, and a raw `posix_spawn` for the updater. Each row below is one of
  their bugs, or one they were written to avoid.
- **POSIX process groups** (`setpgid`, `kill(-pgid, …)`): the one handle on
  "everything this child started" the kernel offers; a process that calls
  `setsid` leaves it, so the descendants are walked too.
- **The kernel's pid rule**: a pid is not given to a new process while a
  process group of that number exists. So while a child's group has a member
  its number is free or the child's own, and a different process holding it
  means the group has gone.
- **swiftlang/swift-subprocess**: considered as a base. Stoic takes on no
  dependency outside a trait, and what this contract adds (the shield, the
  ledger, readiness reads, the input queue, events) is most of the code.

## Rules

1. **The environment is given whole.** No implicit inheritance: a child gets
   exactly the variables the caller names (`ProcessEnvironment.current` to
   pass this process's on, filtered first if something must not reach it).
2. **The program is an absolute path.** No search of `PATH`: which program
   runs is the caller's decision, never the environment's.
3. **Read what you pipe.** A piped output is read only as it is asked for; a
   child whose output nobody reads waits on the pipe. Say `.discard` for what
   nobody will read.
4. **Keep the handle.** An owned child lives as long as its `ChildProcess`;
   releasing the handle stops it (`process.abandoned`).

## API

```swift
public struct Command: Sendable, Hashable {
    public init(_ executable: String, _ arguments: [String] = [], in directory: String? = nil,
                environment: [String: String], input: Input = .none, output: Output = .pipe,
                errors: ErrorOutput = .pipe, lifetime: Lifetime = .owned)
    public enum Input { case none, pipe, inherit, file(String) }
    public enum Output { case pipe, discard, inherit, file(String, append: Bool) }
    public enum ErrorOutput { case pipe, mergeWithOutput, discard, inherit, file(String, append: Bool) }
    public enum Lifetime { case owned, detached }
}
public enum ProcessEnvironment { public static var current: [String: String] }

public final class ChildProcess: Sendable {
    public struct Options { label, drainGrace (2 s), stopGrace (3 s), killWait (5 s), inputCapacity (64 MiB), ledger }
    public static func start(_ command: Command, options: Options = .init()) throws(ProcessError) -> ChildProcess
    public static func run(_ command: Command, timeout: Duration, keepingLast: Int = 64 * 1024,
                           options: Options = .init(), onOutput: (@Sendable ([UInt8]) -> Void)? = nil) async throws -> ProcessResult
    public var pid: Int32 { get }
    public let output: ProcessOutput?, errors: ProcessOutput?, input: ProcessInput?
    public var exit: ProcessExit? { get }
    public var isRunning: Bool { get }
    public func waitForExit() async throws(CancellationError) -> ProcessExit
    public func stop(grace: Duration? = nil) async -> ProcessExit?     // shielded, bounded
    public func terminate(grace: Duration? = nil)                     // stop, not awaited
    public func signal(_ signal: Int32)                                // to the group, while it is ours
}
public struct ProcessOutput: AsyncSequence { // [UInt8] chunks
    public func lines(maxLength:) -> ProcessLines
    public func lineBatches(maxLength:) -> ProcessLineBatches
    public func collect(keepingLast:onChunk:) async -> (bytes: [UInt8], truncated: Bool)
}
public final class ProcessInput: Sendable {
    public func send(_ bytes: [UInt8]) throws(ProcessError)   // and send(_: String)
    public func flush() async
    public func finish()
    public var queued: Int { get }
}
public enum ProcessExit { case exited(Int32), signalled(Int32), vanished }  // succeeded, status
public struct ProcessResult { exit, timedOut, output, outputTruncated, errors; succeeded, outputText, errorsText }
public enum ProcessError: Error, Retryable, Presentable {
    case couldNotStart(executable:errno:), couldNotPrepare(what:errno:), pipeForDetached, inputClosed, inputFull(queued:capacity:)
}
public final class ProcessLedger: Sendable {
    public init(directory: String)
    public func reapOrphans(grace: Duration = .seconds(3)) async -> Int
}
```

macOS only: iOS cannot start processes. The library compiles to nothing
elsewhere, as StoicXPC does.

## Semantics

**Starting.** `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` (the child
gets its three streams and nothing else; never another child's pipe, which
would hold that child's output open), every signal back to its default
disposition and none blocked (an app that ignores `SIGPIPE` must not hand
that on), and `POSIX_SPAWN_SETPGROUP` (`.owned`) or `POSIX_SPAWN_SETSID`
(`.detached`). The pipe ends this process keeps are non-blocking and
close-on-exec from the moment they are made; the write end of an input has
`F_SETNOSIGPIPE`, so a child that has gone is `EPIPE` on that descriptor,
never a signal to the app. A start that fails closes everything it opened.

**Identity.** A child is known by its pid and the start time the kernel
keeps for it to the microsecond. Every signal to anything but an unreaped
child is sent only after checking that the pid still names a process with
that start time. Reaping and signalling run on one serial queue, so a signal
by pid is never sent after the reap that frees the pid.

**Output.** A read happens when the reader asks: a kqueue readiness source
is resumed while someone waits and suspended as soon as it fires. A chunk is
at most 64 KB; `lines` splits them, `lineBatches` hands on every line one read
completed together. The output ends at end of file, when the reading task is
cancelled, or `drainGrace` after the child is reaped once the pipe is empty.
A descriptor is never closed while a read or write is using it.

**Exit.** A process source reports the exit; `waitpid(WNOHANG)` reaps it
(and is tried once after the source is armed, for a child that ended
first). The input is closed before anyone waiting for the exit is told.

**Input.** `send` is synchronous: it appends to a queue (refusing past
`inputCapacity`) and starts the one writer if none runs. Sends are written in
order, each whole.

**Stop.** One stop at a time; later calls join it. It runs in a task of its
own, so the caller's cancellation does not reach it. While the child is
alive its descendants are walked (to find any that left its group), then
`SIGTERM` goes to the group (or, once the child is reaped, to each member
that started after it did, when the group is still the one it led) and to
those descendants. It waits for the child, and for the group, up to the
grace; whatever is left gets `SIGKILL`, and the child is waited for up to
`killWait`.

**Ledger.** An owned child started with a ledger is written to
`<directory>/<own pid>-<own start>.ledger` and crossed out when reaped (the
file replaced each time, never synced: it has to survive a crash of the app,
not of the machine). `reapOrphans` reads every file whose owner is no longer
running, stops what it recorded (and their groups' members, under the
identity rules above), and deletes the file.

## Failure modes

| What happens if…                                                | Behaviour                                                                                        |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| the program cannot be started                                   | `ProcessError.couldNotStart` with the errno; nothing left open; `process.spawn_failed`           |
| a detached child is given a pipe                                | `ProcessError.pipeForDetached`; nothing started                                                  |
| the child exits before its last output is read                  | Every line is still read; the output ends after it                                               |
| the child writes faster than its output is read                 | Nothing is read ahead: the child waits on the full pipe; chunks never exceed 64 KB               |
| something the child started holds its output open after it ends | The output ends `drainGrace` after the child, once the pipe is empty; `process.output_cut`       |
| the child's process group outlives it                           | A stop signals each member that started after the child, while the group is still the one it led |
| a line is longer than the limit                                 | Handed on in pieces of `maxLength`; `process.line_split`                                         |
| many sends are made one after another                           | Written in the order they were made, each whole                                                  |
| the child stops reading its input                               | `send` never blocks; past `inputCapacity` it throws `inputFull` and queues nothing               |
| the child has ended when input is sent                          | `inputClosed`; `flush` returns                                                                   |
| the child ignores SIGTERM                                       | `SIGKILL` after the grace; `process.stop_escalated`                                              |
| the child has started programs of its own                       | A stop ends the whole process group                                                              |
| a descendant leaves the child's process group                   | Found by walking the child's descendants before the stop, and stopped with it                    |
| the caller of a stop is cancelled                               | The stop runs to its end (grace, then `killWait`)                                                |
| the handle is released while the child runs                     | The child and its group are stopped; `process.abandoned`                                         |
| a run passes its deadline                                       | The child is stopped; the result says `timedOut`, with the output written until then             |
| a run's caller is cancelled                                     | The child is stopped; `CancellationError`                                                        |
| this program crashed while its children ran                     | `reapOrphans` at the next launch stops them and their groups; `process.orphans_reaped`           |
| another copy of this program is running                         | Its ledger is left alone while it runs                                                           |
| a recorded pid belongs to another process now                   | Not signalled: its start time does not match                                                     |
| a recorded child ends                                           | Crossed out of the ledger; the file is removed with the last                                     |

## Events

`process.started` (debug), `process.exited` (debug; info for anything but
exit 0), `process.spawn_failed`, `process.abandoned`, `process.stop_escalated`
(warning), `process.unkillable` (error), `process.output_cut` (notice),
`process.line_split` (warning), `process.input_closed` (debug),
`process.orphans_reaped` (notice), `process.ledger_failed` (warning). Events
are recorded through the ambient of the call that started the child, even
when the work is done on a Dispatch queue or a task of the child's own.
Arguments are never recorded: only the program's name and their number.

## Testing

Real processes on real time (`/bin/sh`, `sleep`, `cat`, `yes`): a process
cannot run on a test clock. Every wait is a few hundred milliseconds; every
child is stopped by the end of its test. The ledger is tested with files
written as a crashed run would have left them, for children the test started
detached.

## Not built

- **A simulated process** for deterministic tests of code that drives one
  (as `XPCSimulatedService` is for XPC). Wanted: a session's event ordering
  should be testable without a real child.
- **Pseudo-terminals.** A child that behaves differently on a terminal (colour,
  progress bars, line buffering) is run without one.
- **Linux.** `posix_spawn` is there, but the readiness and process sources and
  the process table are Darwin's.
