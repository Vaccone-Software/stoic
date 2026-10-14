public import Stoic

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#endif

/// A storage operation that failed, and whether trying again could help.
///
/// Every `StoicStore` call throws this one type, so a caller can write one
/// `catch` and one `retry` classification for all of persistence. It
/// conforms to ``Retryable``, so Stoic's `retry` already knows what to do.
///
///     do {
///         try atomicFile.write(bytes, to: path)
///     } catch where error.kind == .diskFull {
///         showStorageFullBanner()
///     }
///
/// ## Retry classification
///
/// - **Stop** (`ENOSPC`, `EROFS`, `EDQUOT`, `EACCES`, `EPERM`, `ENOENT`, ...):
///   the disk is full, read-only, over quota or forbidden. Retrying within
///   seconds changes nothing, and the preflight already refuses early.
/// - **Retry** (`EINTR`, `EAGAIN`, `EBUSY`, `EMFILE`, `ENFILE`, `ENOMEM`):
///   a signal, a lock or a momentary shortage of descriptors or memory.
///   `PosixFileSystem` already restarts `EINTR` itself; the rest retry at the
///   caller's schedule.
/// - **Stop** (`EIO`): the medium reports damage. A retried `fsync` after a
///   failed one can succeed without the data being on disk (the kernel may
///   have dropped the dirty pages), so a retry would prove nothing. Stop and
///   report; a *whole* `AtomicFile.write` starts over from a fresh temporary
///   file and is safe for the app to try again later, but not blindly.
public struct StoreError: Error, Retryable, Sendable, CustomStringConvertible {
    /// What went wrong, coarsely.
    public enum Kind: Sendable, Hashable {
        /// `ENOSPC`, or the free-space preflight refused the write.
        case diskFull
        /// `EROFS`.
        case readOnly
        /// `EDQUOT`.
        case quotaExceeded
        /// `EACCES` or `EPERM`.
        case permissionDenied
        /// `ENOENT`, `ENOTDIR`.
        case notFound
        /// `EEXIST`.
        case alreadyExists
        /// `EINTR`.
        case interrupted
        /// `EAGAIN`, `EBUSY`.
        case busy
        /// `EMFILE`, `ENFILE`, `ENOMEM`.
        case resourceExhausted
        /// `EIO`, or a short write or read the system never explained.
        case ioFailure
        /// Data failed its checksum, framing or validation.
        case corrupt
        /// The platform cannot do what was asked (`ENOTSUP` that has no fallback).
        case unsupported
        /// A caller's argument is out of range (`EINVAL`, a record that is too large,
        /// `EXDEV`: two paths that must share a volume do not).
        case invalidArgument
        /// An earlier failure left the object in a state that needs reopening.
        case poisoned
        /// Anything else; the errno is in ``errnoValue``.
        case other
    }

    public let kind: Kind

    /// The operation that failed, such as `"open"` or `"fsync"`.
    public let operation: String

    /// The path involved, when there is one.
    public let path: String?

    /// The POSIX error number, when the failure came from a system call.
    public let errnoValue: Int32?

    /// Extra explanation, such as which check a corrupt file failed.
    public let detail: String?

    public init(kind: Kind, operation: String, path: String? = nil, errnoValue: Int32? = nil, detail: String? = nil) {
        self.kind = kind
        self.operation = operation
        self.path = path
        self.errnoValue = errnoValue
        self.detail = detail
    }

    /// The error for a failed system call.
    public init(errno code: Int32, operation: String, path: String? = nil) {
        let kind: Kind
        switch code {
        case ENOSPC: kind = .diskFull
        case EROFS: kind = .readOnly
        case EDQUOT: kind = .quotaExceeded
        case EACCES, EPERM: kind = .permissionDenied
        case ENOENT, ENOTDIR: kind = .notFound
        case EEXIST, ENOTEMPTY: kind = .alreadyExists
        case EINTR: kind = .interrupted
        case EAGAIN, EBUSY: kind = .busy
        case EMFILE, ENFILE, ENOMEM: kind = .resourceExhausted
        case EIO: kind = .ioFailure
        case EINVAL, ENAMETOOLONG, EISDIR, EBADF, EFBIG, EXDEV: kind = .invalidArgument
        case ENOTSUP: kind = .unsupported
        default: kind = .other
        }
        // A rename cannot cross volumes, and the bare errno does not say so.
        let detail = code == EXDEV ? "the two paths are on different volumes" : nil
        self.init(kind: kind, operation: operation, path: path, errnoValue: code, detail: detail)
    }

    public var retryDecision: RetryDecision {
        switch kind {
        case .interrupted, .busy, .resourceExhausted: .retry
        case .diskFull, .readOnly, .quotaExceeded, .permissionDenied, .notFound, .alreadyExists,
             .ioFailure, .corrupt, .unsupported, .invalidArgument, .poisoned, .other: .stop
        }
    }

    public var description: String {
        var text = "\(operation) failed: \(kind)"
        if let path { text += " at \(path)" }
        if let errnoValue { text += " (errno \(errnoValue))" }
        if let detail { text += ": \(detail)" }
        return text
    }
}
