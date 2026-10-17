internal import Synchronization

/// A response whose body has not been read yet: the status and headers as
/// they arrived, and the body as a sequence of byte chunks.
///
/// The streaming counterpart of ``HTTPResponse``, for a body too large to
/// hold: a model, an installer, an export. Reading the body is the caller's
/// to do, at the caller's pace; a transport that can (``URLSessionTransport``)
/// stops reading from the connection while the caller lags, so a slow disk
/// slows the download and does not fill memory.
public struct HTTPStreamedResponse: Sendable, CustomStringConvertible {
    public var status: Int
    public var headers: HTTPHeaders
    /// The body, read once and in order. Dropping it, or calling
    /// ``HTTPBodyStream/cancel()``, abandons the transfer.
    public var body: HTTPBodyStream

    public init(status: Int, headers: HTTPHeaders = [:], body: HTTPBodyStream) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Whether the status is 2xx.
    public var isSuccess: Bool { (200..<300).contains(status) }

    /// The status alone: neither the headers nor the body, so a response
    /// printed in a log leaks nothing.
    public var description: String { "HTTP \(status) (streaming)" }
}

/// The body of a streamed response, as chunks of bytes in the order they
/// arrived.
///
/// ```swift
/// let response = try await api.stream(.get(modelURL), maxBytes: limit)
/// for try await chunk in response.body { try file.append(chunk) }
/// ```
///
/// - **One consumer, one pass.** Iterating twice, or from two tasks at once,
///   is not supported: each chunk is delivered once, to whoever asks first.
/// - **Chunks are `[UInt8]`**, not `Data`: the file system and the hashers a
///   download feeds take bytes, so no further conversion is made on the way.
///   A chunk is never empty. Its size is the transport's to choose (a
///   `URLSession` hands over what the network delivered, typically 16 to 64
///   KiB): a consumer that wants fewer, larger writes gathers them.
/// - **Failure ends the sequence.** The iteration throws what the transport
///   threw (`URLError`, ``HTTPTransportError``), or ``HTTPError`` when it
///   comes from ``HTTPClient/stream(_:maxBytes:accepting:idempotencyKey:overrides:)``,
///   or `CancellationError` when the reading task is cancelled; after it,
///   further reads return `nil`.
/// - **Abandoning cancels.** ``cancel()`` stops the transfer at once and a
///   read after it throws `CancellationError`. Dropping the last reference
///   cancels too, so a stream the caller walks away from never holds a
///   connection open.
public final class HTTPBodyStream: AsyncSequence, Sendable {
    public typealias Element = [UInt8]
    public typealias Failure = any Error

    private let source: @Sendable () async throws -> [UInt8]?
    private let abandon: @Sendable () -> Void

    /// A stream whose chunks come from `next`, which returns `nil` at the
    /// end of the body and throws to end it in failure. `cancel` abandons the
    /// transfer behind it; it is called at most once per call of
    /// ``cancel()``, may be called after the body has ended, and must be
    /// harmless then.
    public init(next: @escaping @Sendable () async throws -> [UInt8]?, cancel: @escaping @Sendable () -> Void = {}) {
        source = next
        abandon = cancel
    }

    /// A stream of one chunk holding `bytes` (none, if `bytes` is empty): a
    /// body that was already in memory.
    public convenience init(bytes: [UInt8]) {
        let pending = ChunkQueue(bytes.isEmpty ? [] : [bytes])
        self.init(next: { pending.pop() })
    }

    deinit {
        abandon()
    }

    /// Abandons the transfer. A transport stops reading and drops the
    /// connection; a read that is waiting, or comes later, throws
    /// `CancellationError`.
    public func cancel() {
        abandon()
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let stream: HTTPBodyStream

        public mutating func next() async throws -> [UInt8]? {
            try await stream.source()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(stream: self)
    }
}

extension HTTPBodyStream {
    /// The next chunk: what the iterator does, for a holder of the stream
    /// that is not iterating it.
    func read() async throws -> [UInt8]? {
        try await source()
    }

    /// Up to `limit` bytes from the start of the body, then the transfer is
    /// abandoned: what an error response's excerpt is made of.
    func prefix(_ limit: Int) async throws -> [UInt8] {
        var collected: [UInt8] = []
        while collected.count < limit, let chunk = try await source() {
            collected.append(contentsOf: chunk.prefix(limit - collected.count))
        }
        cancel()
        return collected
    }
}

/// Chunks handed out one at a time, behind a lock.
private final class ChunkQueue: Sendable {
    private let chunks: Mutex<[[UInt8]]>

    init(_ chunks: [[UInt8]]) {
        self.chunks = Mutex(chunks.reversed())
    }

    func pop() -> [UInt8]? {
        chunks.withLock { $0.popLast() }
    }
}
