#if STOIC_CRYPTO
public import Stoic
public import StoicHTTP
public import StoicStore

/// Fetches files and directories of files that are too large to lose to a
/// dropped connection, and puts them where they belong only when they are what
/// they were said to be.
///
/// ```swift
/// let downloader = Downloader(
///     client: HTTPClient(base: huggingFace, transport: URLSessionTransport(configuration: configuration)),
///     operation: Models.download)      // Backend.huggingFace.idempotent("download", length: .long)
///
/// let model = try await withDeadline(.after(.seconds(6 * 3600))) {
///     try await downloader.download(bundle) { progress in model.progress = progress }
/// }
/// ```
///
/// - **Resumable.** What arrives is written to a partial file as it comes, and
///   a connection that is cut, a server that is busy, an app that was quit or
///   a power cut that took the machine is resumed from the bytes already held
///   (`Range`, with `If-Range` carrying the validator the server gave), on the
///   policy's schedule (design/02) which starts over whenever bytes arrive.
///   A server that ignores `Range`, or whose file changed, is fetched from the
///   start again, and a `restarted` event says so.
/// - **Verified while it streams.** The digest is computed as the bytes
///   arrive, never in a second pass over a finished file. A file that does not
///   check is deleted, fetched again from zero once, and if it still does not
///   check, ``DownloadError/digestMismatch(expected:actual:attempts:)``: a
///   file at the destination is always a whole, verified one.
/// - **Durable.** The verified file is `fullSync`ed, renamed over the
///   destination, and the directory synced (design/15), so a crash at any
///   instant leaves the old file or the new one.
/// - **A long operation.** A download is `.long` in design/22's terms: slow is
///   not stuck, so no attempt timeout cuts a transfer that is progressing, and
///   the caller's deadline is what bounds it. Give the downloader the
///   `Backend.Operation` that declares it (`length: .long`, and `readOnly` or
///   `idempotent`, since a download repeats a `GET`), and a download holds one of
///   its backend's slots while it runs, at its urgency and under its breaker;
///   without one it runs under the caller's deadline alone. Either way, set
///   the deadline: an operation whose caller set none gets design/22's default
///   for its urgency, tripled for `.long` (90 s at `.userInitiated`), which is
///   a safety net for a call, not a budget for a model.
/// - **Cancellation is cancellation.** A cancelled download stops promptly,
///   throws `CancellationError`, and is not a failure; it keeps its partial file
///   unless the download says otherwise.
///
/// ``download(_:progress:)`` throws ``DownloadError``, or `CancellationError`
/// when the caller was cancelled, which is never wrapped (it is `any Error`, as
/// `HTTPClient.send` is, for the same reason: a typed error cannot also be
/// cancellation).
public struct Downloader: Sendable {
    public let client: HTTPClient
    public let fileSystem: any FileSystem
    public let policy: DownloadPolicy
    /// Names the downloader in events.
    public let label: String
    /// The declared operation a download runs as, if any.
    public let operation: Backend.Operation?

    /// - Parameters:
    ///   - client: The client that makes the requests, so its base URL, headers,
    ///     redirect rules, breaker and rate limit are the downloads'. Its
    ///     transport decides how bodies are read: a `URLSessionTransport`
    ///     built on the configuration the app needs (`waitsForConnectivity`,
    ///     `allowsExpensiveNetworkAccess`, …) streams with backpressure.
    ///   - fileSystem: Where the files go; the real one by default, a
    ///     `SimulatedFileSystem` in tests.
    ///   - policy: Retries, verification, checkpoints and progress.
    ///   - label: Names the downloader in events.
    ///   - operation: The `.long` operation each download runs as. It must be
    ///     `readOnly` or `idempotent`, and its own schedule never repeats a
    ///     download that failed: the downloader's already did.
    public init(
        client: HTTPClient,
        fileSystem: any FileSystem = PosixFileSystem(),
        policy: DownloadPolicy = .standard,
        label: String = "download",
        operation: Backend.Operation? = nil
    ) {
        if let operation {
            precondition(operation.length == .long, "a download is a long operation: declare it with length: .long")
            precondition(
                operation.safety == .readOnly || operation.safety == .idempotent,
                "a download repeats a GET: declare it readOnly or idempotent, not \(operation.safety)")
        }
        self.client = client
        self.fileSystem = fileSystem
        self.policy = policy
        self.label = label
        self.operation = operation
    }

    /// Downloads one file.
    ///
    /// - Parameters:
    ///   - download: What to fetch and what it must be.
    ///   - progress: Called with where the download is, at most once per
    ///     ``DownloadPolicy/progressInterval`` for a phase and at every change
    ///     of phase, on the downloading task.
    /// - Returns: The file in place, verified, with how it got there.
    /// - Throws: ``DownloadError``, or `CancellationError` if the caller was cancelled.
    public func download(_ download: Download, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> DownloadResult {
        let reporter = ProgressReporter(interval: policy.progressInterval, callback: progress)
        reporter.beginFile(index: 0, of: 1, bytesBefore: 0, totalBytes: download.expectedSize)
        let transfer = FileTransfer(
            download, client: client, disk: Disk(fileSystem: fileSystem), policy: policy, label: label, progress: reporter)
        return try await performing { () async throws(Stop) -> DownloadResult in try await transfer.run() }
    }

    /// Downloads a directory of files and places it atomically.
    ///
    /// - Parameters:
    ///   - bundle: The files, and where the directory goes.
    ///   - progress: As for ``download(_:progress:)``, with the file in progress
    ///     in ``DownloadProgress/fileIndex`` and the bytes of the whole in
    ///     ``DownloadProgress/bytesDone``.
    /// - Returns: The directory in place, and each file's result.
    /// - Throws: ``DownloadError``, or `CancellationError` if the caller was cancelled.
    public func download(_ bundle: DownloadBundle, progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws -> DownloadBundleResult {
        let reporter = ProgressReporter(interval: policy.progressInterval, callback: progress)
        let transfer = BundleTransfer(
            bundle: bundle, client: client, disk: Disk(fileSystem: fileSystem), policy: policy, label: label, progress: reporter)
        return try await performing { () async throws(Stop) -> DownloadBundleResult in try await transfer.run() }
    }

    // MARK: The operation

    /// Runs `body` as an attempt of the declared operation, if there is one,
    /// and says what stopped it as the public API does.
    private func performing<Value>(_ body: () async throws(Stop) -> Value) async throws -> Value {
        guard let operation else {
            do throws(Stop) {
                return try await body()
            } catch {
                throw Self.exposed(error)
            }
        }
        do throws(OperationError<Stop>) {
            return try await operation.perform { _ throws(Stop) in try await body() }
        } catch {
            switch error.stop {
            case .failed(let stop):
                throw Self.exposed(stop)
            case .rejected(let rejection):
                if rejection.reason == .deadlineExceeded { throw DownloadError.deadlineExceeded }
                if rejection.isCancellation { throw CancellationError() }
                throw DownloadError.rejected(rejection)
            case .cancelled:
                throw CancellationError()
            }
        }
    }

    private static func exposed(_ stop: Stop) -> any Error {
        switch stop {
        case .failed(let error): error
        case .cancelled: CancellationError()
        }
    }
}
#endif
