#if os(macOS)
public import Stoic

/// Why a child process could not be started, or could not be written to.
public enum ProcessError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The executable is not there, or is not a program this process may
    /// run. `errno` is the kernel's reason (`ENOENT`, `EACCES`, `ENOEXEC`).
    case couldNotStart(executable: String, errno: Int32)
    /// A pipe, file or directory the child needed could not be opened.
    case couldNotPrepare(what: String, errno: Int32)
    /// A detached child was given a pipe, which would end with this process.
    case pipeForDetached
    /// The child's input is closed: it ended, or its input was finished.
    case inputClosed
    /// More input is waiting to be written than the child's input holds.
    /// Nothing was queued; what was queued before is still written.
    case inputFull(queued: Int, capacity: Int)

    public var description: String {
        switch self {
        case .couldNotStart(let executable, let errno): "could not start \(executable) (errno \(errno))"
        case .couldNotPrepare(let what, let errno): "could not prepare \(what) (errno \(errno))"
        case .pipeForDetached: "a detached child cannot have pipes"
        case .inputClosed: "the child's input is closed"
        case .inputFull(let queued, let capacity): "the child's input is full (\(queued) of \(capacity) bytes queued)"
        }
    }
}

extension ProcessError: Retryable {
    /// A program that is missing or refused stays so; an input that is full
    /// may drain. A closed input does not reopen.
    public var retryDecision: RetryDecision {
        switch self {
        case .inputFull: .retry
        case .couldNotStart(_, let errno), .couldNotPrepare(_, let errno):
            // Out of processes or descriptors for a moment.
            errno == EAGAIN || errno == EMFILE || errno == ENFILE ? .retry : .stop
        case .pipeForDetached, .inputClosed: .stop
        }
    }

    /// A child that could not be started, or whose input was refused before
    /// it was queued, was never given anything.
    public var neverReachedBackend: Bool {
        switch self {
        case .couldNotStart, .couldNotPrepare, .pipeForDetached, .inputFull: true
        case .inputClosed: false
        }
    }
}

extension ProcessError: Presentable {
    /// A program that would not start is this app's to fix, not the
    /// person's: "something went wrong on our side", for support. A full or
    /// closed input is the same disagreement between the app and its child.
    public var presentation: Presentation {
        switch self {
        case .inputFull: Presentation(StoicWording.busy, recovery: .tryAgain)
        default: StoicPresentation.ours
        }
    }
}

internal import Darwin
#endif
