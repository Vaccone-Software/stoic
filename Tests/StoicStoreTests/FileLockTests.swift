import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

@Suite("FileLock")
struct FileLockTests {
    struct Boom: Error {}

    /// Awaits `task` and returns the rejection reason it threw, if it threw one.
    func rejection(of task: Task<Void, any Error>) async -> Rejection.Reason? {
        do {
            try await task.value
            return nil
        } catch {
            return (error as? PolicyError<StoreError>)?.rejection?.reason
        }
    }

    @Test(.failureMode("design/15", "another process holds the lock"))
    func aSecondLockOnTheSamePathIsRefusedUntilTheFirstReleases() throws {
        let dir = try TempDirectory()
        let first = FileLock(path: dir.file("a.lock"))
        let second = FileLock(path: dir.file("a.lock"))   // separate descriptor: conflicts like another process
        #expect(try first.tryAcquire())
        #expect(first.isHeld)
        #expect(try !second.tryAcquire(), "advisory exclusion between two open files")
        #expect(!second.isHeld)
        try first.release()
        #expect(!first.isHeld)
        #expect(try second.tryAcquire())
        #expect(try !first.tryAcquire())
    }

    @Test(.failureMode("design/15", "the holder dies without releasing"))
    func theLockIsFreedWhenTheHolderGoesAway() throws {
        let dir = try TempDirectory()
        let survivor = FileLock(path: dir.file("a.lock"))
        do {
            // Never released: dropping it closes the descriptor, which is
            // what the kernel does for a process that dies holding it.
            let doomed = FileLock(path: dir.file("a.lock"))
            #expect(try doomed.tryAcquire())
            #expect(try !survivor.tryAcquire())
        }
        #expect(try survivor.tryAcquire())
    }

    @Test(.failureMode("design/15", "the lock is acquired twice on one instance"))
    func acquiringTwiceOnOneInstanceIsAnError() throws {
        let dir = try TempDirectory()
        let lock = FileLock(path: dir.file("a.lock"))
        #expect(try lock.tryAcquire())
        #expect(throws: StoreError.self) { try lock.tryAcquire() }
        #expect(lock.isHeld, "the first hold is untouched")
        try lock.release()
        try lock.release()   // harmless
    }

    @Test(.failureMode("design/15", "another process holds the lock"), .timeLimit(.minutes(1)))
    func acquireWaitsOnTheAmbientClockAndTakesTheLockWhenItIsFreed() async throws {
        let dir = try TempDirectory()
        let holder = FileLock(path: dir.file("a.lock"))
        let waiter = FileLock(path: dir.file("a.lock"))
        #expect(try holder.tryAcquire())
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await waiter.acquire(timeout: .seconds(5), pollInterval: .milliseconds(25))
            }
        }
        await clock.waitForSleepers(count: 1)
        #expect(!waiter.isHeld, "polling, not blocking")
        await clock.advance(by: .milliseconds(25))
        await clock.waitForSleepers(count: 1)   // tried again, still held, asleep again
        #expect(!waiter.isHeld)
        try holder.release()
        await clock.advance(by: .milliseconds(25))
        try await task.value
        #expect(waiter.isHeld)
    }

    @Test(.failureMode("design/15", "`acquire` times out"), .timeLimit(.minutes(1)))
    func acquireTimesOutOnTheAmbientClock() async throws {
        let dir = try TempDirectory()
        let holder = FileLock(path: dir.file("a.lock"))
        let waiter = FileLock(path: dir.file("a.lock"))
        #expect(try holder.tryAcquire())
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await waiter.acquire(timeout: .milliseconds(100), pollInterval: .milliseconds(40))
            }
        }
        for _ in 0..<3 {
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(40))
        }
        #expect(await rejection(of: task) == .deadlineExceeded)
        #expect(!waiter.isHeld)
        #expect(holder.isHeld)
    }

    @Test(.failureMode("design/15", "the waiting task is cancelled"), .timeLimit(.minutes(1)))
    func aCancelledWaitLeavesWithoutTheLockAndWithoutAnError() async throws {
        let dir = try TempDirectory()
        let holder = FileLock(path: dir.file("a.lock"))
        let waiter = FileLock(path: dir.file("a.lock"))
        #expect(try holder.tryAcquire())
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await waiter.acquire()   // no timeout: only cancellation ends it
            }
        }
        await clock.waitForSleepers(count: 1)
        task.cancel()
        let reason = await rejection(of: task)
        #expect(reason == .cancelled)
        #expect(!waiter.isHeld)
        try holder.release()
        #expect(try waiter.tryAcquire(), "nothing was left half-taken")
    }

    @Test(.failureMode("design/15", "the waiting task is cancelled"))
    func anAlreadyCancelledCallerIsRefusedBeforeTouchingTheFile() async throws {
        let dir = try TempDirectory()
        let lock = FileLock(path: dir.file("a.lock"))
        let task = Task {
            // Wait to be cancelled, then ask for a lock that is free.
            while !Task.isCancelled { await Task.yield() }
            try await lock.acquire()
        }
        task.cancel()
        #expect(await rejection(of: task) == .cancelled)
        #expect(!lock.isHeld)
    }

    @Test(.failureMode("design/15", "`withLock`'s body throws"))
    func withLockReleasesWhateverTheBodyDoes() async throws {
        let dir = try TempDirectory()
        let lock = FileLock(path: dir.file("a.lock"))
        let other = FileLock(path: dir.file("a.lock"))

        let value = try await lock.withLock { () async -> Int in
            #expect(lock.isHeld)
            #expect((try? other.tryAcquire()) == false, "excluded while the body runs")
            return 7
        }
        #expect(value == 7)
        #expect(!lock.isHeld)

        do {
            try await lock.withLock { () async throws(Boom) in throw Boom() }
            Issue.record("the body's error was swallowed")
        } catch {
            guard case .body = error else { Issue.record("expected .body, got \(error)"); return }
        }
        #expect(!lock.isHeld, "released after the body threw")
        #expect(try other.tryAcquire())
    }

    @Test(.failureMode("design/15", "`withLock`'s body throws"))
    func withLockReportsAnUnavailableLockWithoutRunningTheBody() async throws {
        let dir = try TempDirectory()
        let holder = FileLock(path: dir.file("a.lock"))
        #expect(try holder.tryAcquire())
        let ran = SendableBox(false)
        let path = dir.file("a.lock")
        do throws(FileLockError<Never>) {
            try await FileLock(path: path).withLock(timeout: .zero) { ran.mutate { $0 = true } }
            Issue.record("the lock was free")
        } catch {
            guard case .acquire(let policy) = error else { Issue.record("expected .acquire"); return }
            #expect(policy.rejection?.reason == .deadlineExceeded)
        }
        #expect(!ran.value)
    }

    @Test(.failureMode("design/15", "the file system has no advisory locks"))
    func aFileSystemWithoutLocksSaysSo() throws {
        let lock = FileLock(path: "/lock", fileSystem: NoLocksFileSystem())
        let error = #expect(throws: StoreError.self) { try lock.tryAcquire() }
        #expect(error?.kind == .unsupported)
        #expect(!lock.isHeld)
    }

    @Test func theSimulatedFileSystemModelsTheSameExclusionAndForgetsLocksAtACrash() throws {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/app")
        let first = FileLock(path: "/app/a.lock", fileSystem: disk)
        let second = FileLock(path: "/app/a.lock", fileSystem: disk)
        #expect(try first.tryAcquire())
        #expect(try !second.tryAcquire())
        try first.release()
        #expect(try second.tryAcquire())
        #expect(try !first.tryAcquire())

        disk.crash()   // the process died: its open files, and their locks, are gone
        let after = FileLock(path: "/app/a.lock", fileSystem: disk)
        #expect(try after.tryAcquire())
    }
}

/// A file system that implements none of the optional operations.
private struct NoLocksFileSystem: FileSystem {
    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile { OpenFile(rawValue: 3) }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { [] }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) {}
    func size(of file: OpenFile) throws(StoreError) -> Int { 0 }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) {}
    func fullSync(_ file: OpenFile) throws(StoreError) {}
    func close(_ file: OpenFile) throws(StoreError) {}
    func syncDirectory(_ directory: String) throws(StoreError) {}
    func rename(from source: String, to destination: String) throws(StoreError) {}
    func remove(_ path: String) throws(StoreError) {}
    func list(directory: String) throws(StoreError) -> [String] { [] }
    func exists(_ path: String) throws(StoreError) -> Bool { false }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 { 0 }
    func createDirectory(_ path: String) throws(StoreError) {}
}

@Suite("Journal: cross-process lock")
struct JournalLockTests {
    @Test(.failureMode("design/15", "a journal is opened with `crossProcessLock` while another holds it"))
    func aSecondOpenIsBusyUntilTheFirstCloses() throws {
        let dir = try TempDirectory()
        let options = Journal.Options(crossProcessLock: true)
        let first = try Journal.open(at: dir.file("j.log"), options: options)
        _ = try first.append(bytes("a"))

        let error = #expect(throws: StoreError.self) { try Journal.open(at: dir.file("j.log"), options: options) }
        #expect(error?.kind == .busy)
        #expect(error?.retryDecision == .retry, "busy is worth retrying later")

        try first.close()
        let second = try Journal.open(at: dir.file("j.log"), options: options)
        #expect(try second.replay().records.map { text($0.bytes) } == ["a"])
    }

    @Test(.failureMode("design/15", "the holder dies without releasing"))
    func aDroppedJournalFreesTheLock() throws {
        let dir = try TempDirectory()
        let options = Journal.Options(crossProcessLock: true)
        do {
            let doomed = try Journal.open(at: dir.file("j.log"), options: options)
            _ = try doomed.append(bytes("x"))
        }
        _ = try Journal.open(at: dir.file("j.log"), options: options)
    }

    @Test func theLockIsOptIn() throws {
        let dir = try TempDirectory()
        let first = try Journal.open(at: dir.file("j.log"))
        let second = try Journal.open(at: dir.file("j.log"))
        _ = (first, second)
        #expect(!FileManager.default.fileExists(atPath: dir.file("j.log.lock")), "no lock file unless asked for")
    }

    @Test(.failureMode("design/15", "an open fails after it took the lock"))
    func aFailedOpenGivesTheLockBack() throws {
        let dir = try TempDirectory()
        try AtomicFile().write(bytes("snapshot"), to: dir.file("j.log.snapshot"))
        try flipBit(in: dir.file("j.log.snapshot"), at: 24)   // corrupt: open throws .corrupt
        let options = Journal.Options(crossProcessLock: true)
        let error = #expect(throws: StoreError.self) { try Journal.open(at: dir.file("j.log"), options: options) }
        #expect(error?.kind == .corrupt)
        #expect(try FileLock(path: dir.file("j.log.lock")).tryAcquire(), "not left held by the failed open")
    }

    @Test(.failureMode("design/15", "a journal is opened with `crossProcessLock` while another holds it"), .timeLimit(.minutes(1)))
    func openCanWaitForTheLockOnTheAmbientClock() async throws {
        let dir = try TempDirectory()
        let options = Journal.Options(crossProcessLock: true)
        let first = try Journal.open(at: dir.file("j.log"), options: options)
        let clock = TestClock()
        let task = Task {
            try await withTestAmbient(clock: clock) {
                try await Journal.open(at: dir.file("j.log"), options: options, lockTimeout: .seconds(5))
            }
        }
        await clock.waitForSleepers(count: 1)
        try first.close()
        await clock.advance(by: .milliseconds(25))
        let second = try await task.value
        #expect(try second.replay().records.isEmpty)
    }
}
