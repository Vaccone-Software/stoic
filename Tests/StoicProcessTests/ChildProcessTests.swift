#if os(macOS)
import Darwin
import Stoic
@testable import StoicProcess
import StoicTesting
import Testing

/// Real processes on real time: `/bin/sh`, `sleep`, `cat`. Each waits at
/// most seconds, and every child a test starts is stopped by the end of it.
@Suite("ChildProcess", .timeLimit(.minutes(1)))
struct ChildProcessTests {
    let environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]

    func shell(_ script: String, input: Command.Input = .none, errors: Command.ErrorOutput = .pipe) -> Command {
        Command("/bin/sh", ["-c", script], environment: environment, input: input, errors: errors)
    }

    /// True once `condition` holds, polling for up to `limit`.
    func eventually(within limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: limit)
        while clock.now < end {
            if condition() { return true }
            try? await clock.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func firstLine(of process: ChildProcess) async -> String? {
        var lines = process.output!.lines().makeAsyncIterator()
        return await lines.next()
    }

    // MARK: Starting

    @Test(.stoic(seed: 1), .failureMode("design/33", "the program cannot be started"))
    func aMissingProgramThrows() throws {
        #expect(throws: ProcessError.couldNotStart(executable: "/no/such/program", errno: ENOENT)) {
            try ChildProcess.start(Command("/no/such/program", environment: environment))
        }
        #expect(StoicTest.events.events(named: "process.spawn_failed").count == 1)
    }

    @Test(.stoic(seed: 2), .failureMode("design/33", "a detached child is given a pipe"))
    func aDetachedChildCannotHavePipes() {
        #expect(throws: ProcessError.pipeForDetached) {
            try ChildProcess.start(Command("/bin/echo", environment: environment, output: .pipe, lifetime: .detached))
        }
    }

    @Test(.stoic(seed: 3))
    func theEnvironmentIsExactlyTheOneGiven() async throws {
        let result = try await ChildProcess.run(Command("/usr/bin/env", environment: ["ONLY": "this"]), timeout: .seconds(10))
        #expect(result.outputText == "ONLY=this\n")
    }

    // MARK: Output

    @Test(.stoic(seed: 4), .failureMode("design/33", "the child exits before its last output is read"))
    func everyLineArrivesBeforeTheExit() async throws {
        let process = try ChildProcess.start(shell("i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done; exit 3"))
        // Let it finish and be reaped before anything is read.
        #expect(try await process.waitForExit() == .exited(3))
        var lines: [String] = []
        for await line in process.output!.lines() { lines.append(line) }
        #expect(lines.count == 2000)
        #expect(lines.last == "line1999")
    }

    @Test(.stoic(seed: 5), .failureMode("design/33", "the child writes faster than its output is read"))
    func nothingIsReadAheadOfTheReader() async throws {
        let process = try ChildProcess.start(shell("yes | head -c 2000000"))
        // Unread, the child fills the pipe and waits: it is still running.
        try await Task.sleep(for: .milliseconds(300))
        #expect(process.isRunning)
        var total = 0
        var largest = 0
        for await chunk in process.output! {
            total += chunk.count
            largest = max(largest, chunk.count)
        }
        #expect(total == 2_000_000)
        #expect(largest <= ProcessOutput.chunkSize)
        #expect(try await process.waitForExit().succeeded)
    }

    @Test(.stoic(seed: 6), .failureMode("design/33", "something the child started holds its output open after it ends"))
    func theOutputEndsAGraceAfterTheChild() async throws {
        let process = try ChildProcess.start(shell("sleep 30 & echo started"), options: .init(drainGrace: .milliseconds(300)))
        let clock = ContinuousClock()
        let start = clock.now
        var lines: [String] = []
        for await line in process.output!.lines() { lines.append(line) }
        #expect(lines == ["started"])
        // Well short of the background program's thirty seconds, with room
        // for a machine busy with the rest of the suite.
        #expect(start.duration(to: clock.now) < .seconds(10))
        #expect(StoicTest.events.events(named: "process.output_cut").count == 1)
        await process.stop(grace: .milliseconds(300))
    }

    @Test(.stoic(seed: 7), .failureMode("design/33", "the child's process group outlives it"))
    func aStopAfterTheExitEndsWhatTheChildLeftRunning() async throws {
        let process = try ChildProcess.start(shell("sleep 30 & echo $!"), options: .init(drainGrace: .milliseconds(100)))
        let line = await firstLine(of: process)
        let background = try #require(line.flatMap { Int32($0) }.flatMap(ProcessIdentity.of))
        _ = try await process.waitForExit()
        #expect(background.isAlive)
        await process.stop(grace: .milliseconds(500))
        #expect(await eventually { !background.isAlive })
    }

    @Test(.stoic(seed: 8), .failureMode("design/33", "a line is longer than the limit"))
    func anOverlongLineIsSplit() async throws {
        let process = try ChildProcess.start(shell("head -c 250000 /dev/zero | tr '\\000' a; echo; echo end"))
        var lengths: [Int] = []
        for await line in process.output!.lines(maxLength: 100_000) { lengths.append(line.count) }
        #expect(lengths == [100_000, 100_000, 50_000, 3])
        #expect(StoicTest.events.events(named: "process.line_split").count == 2)
    }

    @Test(.stoic(seed: 9))
    func lineBatchesHoldEveryLineOfARead() async throws {
        let process = try ChildProcess.start(shell("printf 'a\\nb\\nc\\n'; sleep 0.2; printf 'd\\ne'"))
        var batches: [[String]] = []
        for await batch in process.output!.lineBatches() { batches.append(batch) }
        #expect(batches.flatMap(\.self) == ["a", "b", "c", "d", "e"])
        #expect(batches.first == ["a", "b", "c"])
    }

    @Test(.stoic(seed: 10))
    func errorsMergedWithOutputKeepTheirOrder() async throws {
        let result = try await ChildProcess.run(shell("echo one; echo two >&2; echo three", errors: .mergeWithOutput),
                                                timeout: .seconds(10))
        #expect(result.outputText == "one\ntwo\nthree\n")
        #expect(result.errors.isEmpty)
    }

    // MARK: Input

    @Test(.stoic(seed: 11), .failureMode("design/33", "many sends are made one after another"))
    func sendsAreWrittenInOrder() async throws {
        let process = try ChildProcess.start(Command("/bin/cat", environment: environment, input: .pipe))
        for index in 0..<2000 { try process.input!.send("message \(index)\n") }
        process.input!.finish()
        var lines: [String] = []
        for await line in process.output!.lines() { lines.append(line) }
        #expect(lines == (0..<2000).map { "message \($0)" })
        #expect(try await process.waitForExit().succeeded)
    }

    @Test(.stoic(seed: 12), .failureMode("design/33", "the child stops reading its input"))
    func aSendNeverBlocksAndAFullInputRefuses() async throws {
        let process = try ChildProcess.start(Command("/bin/sleep", ["30"], environment: environment, input: .pipe),
                                             options: .init(inputCapacity: 1_000_000))
        let clock = ContinuousClock()
        let start = clock.now
        let chunk = [UInt8](repeating: 0x61, count: 100_000)
        var refused: ProcessError?
        for _ in 0..<100 {
            do { try process.input!.send(chunk) } catch {
                refused = error
                break
            }
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
        guard case .inputFull(_, let capacity) = refused else {
            Issue.record("expected inputFull, got \(String(describing: refused))")
            return
        }
        #expect(capacity == 1_000_000)
        await process.stop(grace: .milliseconds(300))
    }

    @Test(.stoic(seed: 13), .failureMode("design/33", "the child has ended when input is sent"))
    func inputAfterTheExitIsRefused() async throws {
        let process = try ChildProcess.start(Command("/usr/bin/true", environment: environment, input: .pipe))
        _ = try await process.waitForExit()
        #expect(throws: ProcessError.inputClosed) { try process.input!.send("late\n") }
        await process.input!.flush()   // returns: nothing will be written
    }

    // MARK: Stopping

    @Test(.stoic(seed: 14), .failureMode("design/33", "the child ignores SIGTERM"))
    func aChildThatIgnoresTermIsKilled() async throws {
        let process = try ChildProcess.start(shell("trap '' TERM; echo ready; sleep 30"))
        #expect(await firstLine(of: process) == "ready")
        let exit = await process.stop(grace: .milliseconds(300))
        #expect(exit == .signalled(SIGKILL))
        #expect(StoicTest.events.events(named: "process.stop_escalated").count == 1)
    }

    @Test(.stoic(seed: 15), .failureMode("design/33", "the child has started programs of its own"))
    func aStopEndsTheWholeGroup() async throws {
        let process = try ChildProcess.start(shell("sleep 30 & echo $!; sleep 30 & echo $!; wait"))
        var iterator = process.output!.lines().makeAsyncIterator()
        var started: [ProcessIdentity] = []
        for _ in 0..<2 {
            if let line = await iterator.next(), let pid = Int32(line), let child = ProcessIdentity.of(pid) { started.append(child) }
        }
        #expect(started.count == 2)
        let exit = await process.stop(grace: .seconds(2))
        #expect(exit == .signalled(SIGTERM))
        #expect(await eventually { started.allSatisfy { !$0.isAlive } })
    }

    @Test(.stoic(seed: 16), .enabled(if: perlIsInstalled()),
          .failureMode("design/33", "a descendant leaves the child's process group"))
    func aDescendantInASessionOfItsOwnIsStoppedToo() async throws {
        let process = try ChildProcess.start(shell("/usr/bin/perl -e 'use POSIX; setsid(); print \"$$\\n\"; $| = 1; sleep 30' & wait"))
        let line = await firstLine(of: process)
        let escaped = try #require(line.flatMap { Int32($0) }.flatMap(ProcessIdentity.of))
        #expect(getpgid(escaped.pid) != process.pid)
        await process.stop(grace: .seconds(2))
        #expect(await eventually { !escaped.isAlive })
    }

    @Test(.stoic(seed: 17), .failureMode("design/33", "the caller of a stop is cancelled"))
    func aStopIsShieldedFromItsCaller() async throws {
        let process = try ChildProcess.start(Command("/bin/sleep", ["30"], environment: environment))
        let stopping = Task { await process.stop(grace: .seconds(2)) }
        stopping.cancel()
        #expect(await stopping.value == .signalled(SIGTERM))
        #expect(!process.isRunning)
    }

    @Test(.stoic(seed: 18), .failureMode("design/33", "the handle is released while the child runs"))
    func aReleasedHandleStopsItsChild() async throws {
        var identity: ProcessIdentity?
        do {
            let process = try ChildProcess.start(Command("/bin/sleep", ["30"], environment: environment),
                                                 options: .init(stopGrace: .milliseconds(300)))
            identity = ProcessIdentity.of(process.pid)
        }
        let child = try #require(identity)
        #expect(await eventually { !child.isAlive })
        #expect(StoicTest.events.events(named: "process.abandoned").count == 1)
    }

    // MARK: Run

    @Test(.stoic(seed: 19), .failureMode("design/33", "a run passes its deadline"))
    func aRunPastItsDeadlineSaysSoWithItsOutput() async throws {
        let result = try await ChildProcess.run(shell("echo before; sleep 30"), timeout: .seconds(2))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(result.outputText == "before\n")
        #expect(result.exit == .signalled(SIGTERM))
    }

    @Test(.stoic(seed: 20), .failureMode("design/33", "a run's caller is cancelled"))
    func aCancelledRunStopsItsChildAndThrows() async throws {
        let pid = SendableBox<Int32?>(nil)
        let running = Task {
            try await ChildProcess.run(shell("echo $$; sleep 30"), timeout: .seconds(30)) { chunk in
                let line = String(decoding: chunk, as: UTF8.self).split(separator: "\n").first.map(String.init)
                pid.mutate { found in found = found ?? line.flatMap { Int32($0) } }
            }
        }
        #expect(await eventually { pid.value != nil })
        let child = try #require(pid.value.flatMap(ProcessIdentity.of))
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await eventually { !child.isAlive })
    }

    @Test(.stoic(seed: 21))
    func aRunReportsItsExit() async throws {
        let result = try await ChildProcess.run(shell("echo out; echo err >&2; exit 4"), timeout: .seconds(10))
        #expect(result.exit == .exited(4))
        #expect(result.exit?.status == 4)
        #expect(result.outputText == "out\n")
        #expect(result.errorsText == "err\n")
        #expect(StoicTest.events.events(named: "process.exited").count == 1)
    }
}

/// Perl's `setsid` makes a process that leaves its parent's group.
func perlIsInstalled() -> Bool { unsafe access("/usr/bin/perl", X_OK) == 0 }
#endif
