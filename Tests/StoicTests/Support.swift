import Dispatch
import Foundation
import Synchronization

/// How much to multiply the size of every property and model test by.
/// The default keeps the suite fast; `STOIC_TEST_SCALE=20 swift test` hunts
/// harder, and a failure still names its seed.
let testScale: Int = {
    ProcessInfo.processInfo.environment["STOIC_TEST_SCALE"].flatMap(Int.init).map { max(1, $0) } ?? 1
}()

/// Whether a sanitizer instruments this process. The child process an exit
/// test starts does not get the sanitizer's runtime and aborts before its
/// body runs ("interceptors are not working"), so exit tests that expect a
/// clean exit are skipped under one; the plain test step runs them.
let underSanitizer: Bool = {
    // A symbol lookup across every loaded image (RTLD_DEFAULT); nothing is
    // read through the pointers. The constant is a macro Swift does not
    // import: Darwin defines it as -2, glibc as null, and a handle of -2 on
    // glibc is a wild pointer that crashes `dlsym`.
    #if canImport(Darwin)
    let everywhere = unsafe UnsafeMutableRawPointer(bitPattern: -2)
    #else
    let everywhere: UnsafeMutableRawPointer? = nil
    #endif
    return unsafe dlsym(everywhere, "__tsan_init") != nil || dlsym(everywhere, "__asan_init") != nil
}()

/// What a program run to its end printed, and how it ended.
struct ProgramRun: Sendable {
    let status: Int32
    let output: String
}

/// Runs a program to its end without blocking the cooperative pool.
///
/// Foundation's `Process` is waited for with blocking calls
/// (`readDataToEndOfFile`, `waitUntilExit`). Made from a test, they hold one of
/// the pool's threads, which are as many as the machine has cores (three or
/// four on a CI runner), for as long as the program runs, and every other test
/// in the bundle waits for those threads. A dedicated thread waits instead.
/// At `timeout`, or when the test is cancelled, the program is terminated and
/// the result is nil at once, whether or not its output has ended (a compiler
/// it started may still hold the pipe), so a program that does not finish
/// fails its test rather than hanging the bundle.
func runOffThePool(_ executable: URL, _ arguments: [String], timeout: Duration = .seconds(180)) async throws -> ProgramRun? {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let program = RunningProgram(process)
    let pending = SendableBox<CheckedContinuation<ProgramRun?, Never>?>(nil)
    @Sendable func settle(_ run: ProgramRun?) -> Bool {
        guard let continuation = pending.mutate({ waiting -> CheckedContinuation<ProgramRun?, Never>? in
            defer { waiting = nil }
            return waiting
        }) else { return false }
        continuation.resume(returning: run)
        return true
    }
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProgramRun?, Never>) in
            pending.mutate { $0 = continuation }
            Thread {
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                program.process.waitUntilExit()
                _ = settle(ProgramRun(status: program.process.terminationStatus,
                                      output: String(decoding: output, as: UTF8.self)))
            }.start()
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if settle(nil) { program.process.terminate() }
            }
        }
    } onCancel: {
        if settle(nil) { program.process.terminate() }
    }
}

/// A started `Process`, handed to the thread that waits for it and to the
/// timer that may end it. `Process` is not `Sendable`; it is safe here
/// because after `run()` it is only waited for, read and terminated, which
/// Foundation allows from any thread.
private final class RunningProgram: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// A value shared between test tasks behind a lock.
final class SendableBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var value: Value {
        storage.withLock { $0 }
    }

    func mutate<R: Sendable>(_ body: (inout Value) -> R) -> R {
        storage.withLock { body(&$0) }
    }
}

/// Polls `condition` until it holds or `limit` of real time passes. For
/// waiting on work that runs on other tasks, where a fixed number of yields
/// is not enough under load.
@discardableResult
func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while !condition() {
        if clock.now >= deadline { return false }
        try? await clock.sleep(for: .milliseconds(1))
    }
    return true
}

/// Whether `invariant` stays true for `window` of real time: the way to
/// assert that something does *not* happen. Use it only after a positive
/// signal that the thing would have happened by now if it were going to
/// (a gate that was opened, a task that was woken), and never in place of one.
func holdsThroughout(for window: Duration = .milliseconds(30), _ invariant: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now.advanced(by: window)
    while clock.now < end {
        if !invariant() { return false }
        try? await clock.sleep(for: .milliseconds(1))
    }
    return invariant()
}
