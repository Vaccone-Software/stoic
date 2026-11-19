#if os(macOS)
import Darwin
import Stoic
@testable import StoicProcess
import StoicTesting
import Testing

/// The ledger read as the next launch reads it: files written as a run that
/// crashed would have left them, for children this test started.
@Suite("ProcessLedger", .timeLimit(.minutes(1)))
struct ProcessLedgerTests {
    let environment = ["PATH": "/usr/bin:/bin"]

    func temporaryDirectory() -> String {
        var template = Array("/tmp/stoic-ledger.XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { unsafe mkdtemp($0.baseAddress!) }
        return unsafe String(cString: made!)
    }

    /// A child left as a crashed run would leave it: running, in a group of
    /// its own, no handle in this run (it is detached, so this test's
    /// releasing it does not stop it).
    func orphan() throws -> ProcessIdentity {
        let process = try ChildProcess.start(Command("/bin/sleep", ["30"], environment: environment,
                                                     output: .discard, errors: .discard, lifetime: .detached))
        return try #require(ProcessIdentity.of(process.pid))
    }

    func write(_ entries: [ProcessIdentity], owner: ProcessIdentity, in directory: String) {
        let text = entries.map { "\($0.pid) \($0.started) test\n" }.joined()
        let path = directory + "/\(owner.pid)-\(owner.started).ledger"
        let fd = unsafe open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        _ = Array(text.utf8).withUnsafeBytes { unsafe Darwin.write(fd, $0.baseAddress, $0.count) }
        _ = close(fd)
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// No process has this identity: pid 1 is launchd, which started long
    /// before the epoch's first microsecond.
    let deadOwner = ProcessIdentity(pid: 1, started: 1)

    @Test(.stoic(seed: 1), .failureMode("design/33", "this program crashed while its children ran"))
    func aCrashedRunsChildrenAreStopped() async throws {
        let directory = temporaryDirectory()
        let child = try orphan()
        write([child], owner: deadOwner, in: directory)
        let reaped = await ProcessLedger(directory: directory).reapOrphans(grace: .milliseconds(500))
        #expect(reaped == 1)
        #expect(await eventually { !child.isAlive })
        #expect(StoicTest.events.events(named: "process.orphans_reaped").count == 1)
        #expect(unsafe access(directory + "/\(deadOwner.pid)-\(deadOwner.started).ledger", F_OK) != 0)
    }

    @Test(.stoic(seed: 2), .failureMode("design/33", "another copy of this program is running"))
    func aLiveRunsChildrenAreLeftAlone() async throws {
        let directory = temporaryDirectory()
        let owner = try orphan()
        let child = try orphan()
        write([child], owner: owner, in: directory)
        #expect(await ProcessLedger(directory: directory).reapOrphans(grace: .milliseconds(200)) == 0)
        #expect(child.isAlive)
        for process in [owner, child] { process.signal(SIGKILL) }
    }

    @Test(.stoic(seed: 3), .failureMode("design/33", "a recorded pid belongs to another process now"))
    func aReusedPidIsNeverSignalled() async throws {
        let directory = temporaryDirectory()
        let stranger = try orphan()
        // The pid as a process that has since ended would have recorded it.
        write([ProcessIdentity(pid: stranger.pid, started: stranger.started - 1)], owner: deadOwner, in: directory)
        #expect(await ProcessLedger(directory: directory).reapOrphans(grace: .milliseconds(200)) == 0)
        #expect(stranger.isAlive)
        stranger.signal(SIGKILL)
    }

    @Test(.stoic(seed: 4), .failureMode("design/33", "a recorded child ends"))
    func aChildIsCrossedOutWhenItEnds() async throws {
        let directory = temporaryDirectory()
        let ledger = ProcessLedger(directory: directory)
        let path = directory + "/\(ProcessIdentity.own.pid)-\(ProcessIdentity.own.started).ledger"
        let process = try ChildProcess.start(Command("/bin/sleep", ["30"], environment: environment),
                                             options: .init(ledger: ledger))
        let recorded = ProcessLedger.read(path)
        #expect(recorded.map(\.0.pid) == [process.pid])
        await process.stop(grace: .milliseconds(300))
        #expect(await eventually { unsafe access(path, F_OK) != 0 })
    }
}
#endif
