#if STOIC_CRYPTO
public import Stoic
public import StoicHTTP
public import StoicStore

/// Why a download ended without the file.
///
/// A download is its own retry layer: it retries a connection that was cut or
/// a server that was busy for as long as its schedule and the caller's deadline
/// allow, resuming where it was. So an error that reaches the caller is final
/// as far as the downloader goes: whether to try again later (after the user
/// fixed the network, or freed some space) is the caller's. Which is why this
/// type is `Retryable` with one answer, `.stop`: an enclosing `retry` or
/// `perform` must not repeat what the downloader already repeated.
///
/// A caller that is cancelled gets `CancellationError`, never one of these:
/// cancelling is not a failure, and is never wrapped.
public enum DownloadError: Error, Sendable, CustomStringConvertible {
    /// The server's or the network's answer ended the download, and trying
    /// again would not change it: a `404`, a `403`, a refused redirect. (A
    /// `503` or a lost connection is retried, not reported, unless the
    /// schedule is spent: ``retriesExhausted(attempts:last:)``.)
    case http(HTTPError)

    /// The schedule ran out: `attempts` requests were made, and `last` is how
    /// the last one failed. Only a schedule with a bound ends this way; the
    /// default one has none.
    case retriesExhausted(attempts: Int, last: HTTPError)

    /// The file arrived whole and its digest is not `expected`: `actual` is
    /// what it is. It was fetched `attempts` times from the start (the
    /// policy's ``DownloadPolicy/verificationAttempts``) and the partial file
    /// is deleted, so a caller that tries again starts from nothing.
    case digestMismatch(expected: ContentDigest, actual: String, attempts: Int)

    /// The server's file is not the size the download was pinned to: it says
    /// it has `reported` bytes and `expected` were asked for. Fetching it
    /// would only produce a file that fails its size.
    case sizeMismatch(expected: Int, reported: Int)

    /// The body is longer than the download's byte limit. The partial file is
    /// deleted.
    case byteLimitExceeded(limit: Int)

    /// The volume has `available` bytes free and the download needs `required`
    /// (``Download/requiredFreeBytes``, or what is left to fetch and a margin).
    /// Nothing was fetched.
    case insufficientSpace(required: UInt64, available: UInt64)

    /// A file operation failed. Placing a file whose last directory sync
    /// failed is not this: the file is in place (``DownloadResult/isDurable``).
    case store(StoreError)

    /// The server answered something that cannot be the file: `reason` says
    /// what (a `204`, a `206` with no `Content-Range`, a range it keeps
    /// answering wrongly).
    case badResponse(status: Int, reason: String)

    /// The caller's deadline passed (or a wait for the next attempt would
    /// have outlasted it). The partial file is kept, whatever
    /// ``Download/keepsPartialOnCancel`` says: the time ran out, nobody
    /// cancelled.
    case deadlineExceeded

    /// A policy around the download refused it before it began: an
    /// enclosing operation's breaker is open, its capacity is full, or its
    /// budget is spent (design/22).
    case rejected(Rejection)

    public var description: String {
        switch self {
        case .http(let error): "the server's answer ended the download: \(error)"
        case .retriesExhausted(let attempts, let last): "gave up after \(attempts) requests, the last failing with \(last)"
        case .digestMismatch(let expected, let actual, let attempts):
            "the file is \(expected.algorithm):\(actual), not \(expected), after \(attempts) \(attempts == 1 ? "fetch" : "fetches")"
        case .sizeMismatch(let expected, let reported): "the server's file is \(reported) bytes, not \(expected)"
        case .byteLimitExceeded(let limit): "the body is longer than the limit of \(limit) bytes"
        case .insufficientSpace(let required, let available): "\(required) bytes are needed and \(available) are free"
        case .store(let error): "file operation failed: \(error)"
        case .badResponse(let status, let reason): "HTTP \(status) cannot be the file: \(reason)"
        case .deadlineExceeded: "the deadline passed"
        case .rejected(let rejection): "rejected: \(rejection)"
        }
    }

    /// A short, public name for the kind of error, for events: the text of
    /// the error may hold a path.
    var kind: String {
        switch self {
        case .http: "http"
        case .retriesExhausted: "retries_exhausted"
        case .digestMismatch: "digest_mismatch"
        case .sizeMismatch: "size_mismatch"
        case .byteLimitExceeded: "byte_limit_exceeded"
        case .insufficientSpace: "insufficient_space"
        case .store: "store"
        case .badResponse: "bad_response"
        case .deadlineExceeded: "deadline_exceeded"
        case .rejected: "rejected"
        }
    }

    /// Whether the partial file is no use after this error: its bytes are
    /// not the file (they failed their digest, or went past the limit).
    var invalidatesPartial: Bool {
        switch self {
        case .digestMismatch, .byteLimitExceeded, .sizeMismatch: true
        default: false
        }
    }
}

extension DownloadError: Retryable {
    /// Always `.stop`: the downloader was the retry layer.
    public var retryDecision: RetryDecision { .stop }
}

/// What ends a transfer inside the downloader: a failure to report, or the
/// caller's cancellation, which is neither a failure nor wrapped (it leaves
/// the public API as `CancellationError`). Internal flow is typed with it, so
/// each step says in its signature what can stop it.
enum Stop: Error, Sendable, Retryable {
    case failed(DownloadError)
    case cancelled

    /// A declared operation that runs a download must not repeat it: the
    /// downloader's own schedule did the repeating.
    var retryDecision: RetryDecision { .stop }
}

extension Stop {
    init(_ error: DownloadError) { self = .failed(error) }
    init(_ error: StoreError) { self = .failed(.store(error)) }

    /// The stop that a cancelled task is: the caller's deadline passing is
    /// `deadlineExceeded` (a rejection, as for `send`), and anything else is
    /// the caller's cancellation, which is not a failure.
    static var cancellation: Stop {
        if CancellationCause.current == .deadline || Deadline.current?.hasPassed == true { return .failed(.deadlineExceeded) }
        return .cancelled
    }
}
#endif
