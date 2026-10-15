public import Stoic
internal import Synchronization

/// An advisory lock on a file, held across processes.
///
/// `AtomicFile` and `Journal` assume one writer per path. Inside a process
/// that is the caller's discipline; between processes (an app and its
/// helper, two launches of a command-line tool) nothing enforces it, and two
/// writers corrupt each other. A `FileLock` on a sidecar file is the
/// enforcement: whoever holds it writes, and the other waits or fails.
///
///     let lock = FileLock(path: dir + "/store.lock")
///     try await lock.withLock(timeout: .seconds(2)) {
///         try journal.append(record)
///     }
///
/// ## Contract
///
/// - **Advisory, per open file.** It is `flock(LOCK_EX)`. Only a process that
///   also takes the lock is kept out; a writer that ignores it is not.
///   Because the lock belongs to the open file and not to the process, two
///   `FileLock`s on one path conflict even inside one process.
/// - **Released by the OS.** Releasing, dropping the `FileLock`, and the
///   process dying (a crash, a kill) all free it: the kernel drops a lock
///   with its descriptor, so a dead holder never wedges the next one and
///   there is no stale lock file to detect. The file itself is never
///   removed (removing it would let two processes lock two different files
///   of one name).
/// - **Never blocks a thread.** `acquire` tries without waiting and, if the
///   lock is held, sleeps on the *ambient clock* between tries. It honours
///   cancellation and ``Deadline/current`` as every Stoic wait does, and a
///   test clock drives it.
/// - **Not reentrant.** Acquiring a lock this instance already holds is an
///   error, not a second hold.
///
/// ## What it does not protect
///
/// - **Network file systems.** `flock` over NFS, SMB or FUSE may be local to
///   the client, emulated with byte-range locks, or refused. Two machines
///   sharing a volume can both "hold" the lock.
/// - **Writers that do not take it**: another tool, a backup that rewrites
///   the file, a user in a text editor.
/// - **A path reached through different names** that the file system does
///   not resolve to one file (a bind mount in another namespace).
/// - **Ordering of what is written.** The lock keeps writers apart; it does
///   not make a reader that never locks see a consistent file. Readers of an
///   ``AtomicFile`` already do (rename is atomic).
public final class FileLock: Sendable {
    public let path: String
    public let fileSystem: any FileSystem

    private let held = Mutex<OpenFile?>(nil)

    public init(path: String, fileSystem: any FileSystem = PosixFileSystem()) {
        self.path = path
        self.fileSystem = fileSystem
    }

    deinit {
        // Closing the descriptor releases the lock; nothing can be reported
        // from a deinit, and a failed close leaves nothing held that the OS
        // does not drop at exit.
        if let file = held.withLock({ $0 }) {
            do throws(StoreError) {
                try fileSystem.close(file)
            } catch {}  // stoic:allow(swallowed-error): nothing can be reported from a deinit (see above)
        }
    }

    /// Whether this instance holds the lock.
    public var isHeld: Bool { held.withLock { $0 != nil } }

    /// Takes the lock if it is free, without waiting.
    ///
    /// - Returns: `false` if another holder has it.
    /// - Throws: `.invalidArgument` if this instance already holds it; any
    ///   other `StoreError` if the lock file cannot be opened or locked.
    public func tryAcquire() throws(StoreError) -> Bool {
        try held.withLock { (held) throws(StoreError) -> Bool in
            if held != nil {
                throw StoreError(kind: .invalidArgument, operation: "flock", path: path, detail: "this FileLock already holds the lock")
            }
            let file = try fileSystem.open(path, mode: .readWriteCreate)
            let locked: Bool
            do throws(StoreError) {
                locked = try fileSystem.tryLock(file)
            } catch {
                do throws(StoreError) {
                    try fileSystem.close(file)
                } catch {
                    // The lock failure is the one worth reporting.
                }
                throw error
            }
            if locked {
                held = file
                return true
            }
            try fileSystem.close(file)
            return false
        }
    }

    /// Waits for the lock.
    ///
    /// Polls every `pollInterval` of the ambient clock until the lock is
    /// free, `timeout` has passed, ``Deadline/current`` has passed, or the
    /// task is cancelled. A cancelled caller leaves without the lock and
    /// without an error to report: the rejection is `.cancelled`.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait; `nil` waits as long as the enclosing
    ///     deadline (if any) allows.
    ///   - pollInterval: How long to sleep between tries. A holder that
    ///     releases is noticed within one interval.
    /// - Throws: `.rejected` (`deadlineExceeded` or `cancelled`) when the lock
    ///   was not taken; `.failed` with the `StoreError` when the file could
    ///   not be opened or locked.
    public func acquire(
        timeout: Duration? = nil,
        pollInterval: Duration = .milliseconds(25)
    ) async throws(PolicyError<StoreError>) {
        precondition(pollInterval > .zero, "FileLock.acquire: pollInterval must be positive")
        let clock = Ambient.current.clock
        var deadline: Deadline? = timeout.map { Deadline.after($0) }
        if let enclosing = Deadline.current { deadline = deadline.map { $0.earlier(enclosing) } ?? enclosing }

        while true {
            if Task.isCancelled { throw .rejected(Rejection(cancellationReason(), label: path)) }
            do throws(StoreError) {
                if try tryAcquire() { return }
            } catch {
                throw .failed(error)
            }
            var step = pollInterval
            if let deadline {
                if deadline.hasPassed { throw .rejected(Rejection(.deadlineExceeded, label: path)) }
                step = min(step, deadline.remaining)
            }
            do {
                try await clock.sleep(until: clock.now.advanced(by: step), tolerance: nil)
            } catch {
                throw .rejected(Rejection(cancellationReason(), label: path))
            }
        }
    }

    /// Releases the lock. Harmless if it is not held.
    public func release() throws(StoreError) {
        try held.withLock { (held) throws(StoreError) in
            guard let file = held else { return }
            held = nil
            // Closing releases the lock even if the explicit unlock fails.
            do throws(StoreError) {
                try fileSystem.unlock(file)
            } catch {
                do throws(StoreError) {
                    try fileSystem.close(file)
                } catch {}
                throw error
            }
            try fileSystem.close(file)
        }
    }

    /// Runs `body` holding the lock, and releases it when `body` ends,
    /// however it ends.
    ///
    /// - Throws: ``FileLockError/acquire(_:)`` if the lock was not taken, or
    ///   ``FileLockError/body(_:)`` with `body`'s error. A failure to release
    ///   after a body that succeeded is thrown as `.acquire(.failed(_))`.
    public nonisolated(nonsending) func withLock<R, Failure: Error>(
        timeout: Duration? = nil,
        pollInterval: Duration = .milliseconds(25),
        _ body: nonisolated(nonsending) () async throws(Failure) -> R
    ) async throws(FileLockError<Failure>) -> R {
        do throws(PolicyError<StoreError>) {
            try await acquire(timeout: timeout, pollInterval: pollInterval)
        } catch {
            throw .acquire(error)
        }
        let outcome: Result<R, Failure>
        do throws(Failure) {
            outcome = .success(try await body())
        } catch {
            outcome = .failure(error)
        }
        // Released even when the task was cancelled while the body ran: the
        // release is a synchronous call and does not wait on anything.
        do throws(StoreError) {
            try release()
        } catch {
            if case .success = outcome { throw .acquire(.failed(error)) }
        }
        switch outcome {
        case .success(let value): return value
        case .failure(let failure): throw .body(failure)
        }
    }
}

/// Why ``FileLock/withLock(timeout:pollInterval:_:)`` threw.
public enum FileLockError<Failure: Error>: Error, CustomStringConvertible {
    /// The lock was not taken (or not released): `body` did not run (or its
    /// result is discarded).
    case acquire(PolicyError<StoreError>)
    /// `body` ran and threw.
    case body(Failure)

    public var description: String {
        switch self {
        case .acquire(let error): "file lock: \(error)"
        case .body(let error): "\(error)"
        }
    }
}

private func cancellationReason() -> Rejection.Reason {
    CancellationCause.current == .deadline ? .deadlineExceeded : .cancelled
}
