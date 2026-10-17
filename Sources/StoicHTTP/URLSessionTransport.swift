public import Foundation
#if canImport(FoundationNetworking)
// URLSession and HTTPURLResponse live here on Linux.
public import FoundationNetworking
#endif
internal import Synchronization

/// The real transport: one `URLSession` data task per request.
///
/// What it adds to the session, and why:
///
/// - **Streaming with backpressure** (``stream(_:maxResponseBytes:)``). The
///   body reaches the caller as the delegate hands it over, chunk by chunk,
///   never a byte at a time (`URLSession.bytes(for:)` pays an async hop per
///   byte, which a 20 GB model cannot afford). The chunks wait in a buffer of
///   bounded size; when a consumer lags and the buffer fills, the data task is
///   *suspended*, so the system stops reading from the connection and TCP's
///   window closes, and it is resumed once the consumer has drained the
///   buffer to a quarter. A slow disk slows the download; it does not
///   fill memory. **On Apple platforms only:** swift-corelibs-foundation
///   restarts a suspended data task from its first byte when it is resumed, so
///   on Linux the task is never suspended and the buffer holds whatever the
///   consumer has not yet taken.
///
/// - **A byte limit enforced while reading.** The body is collected from the
///   task's delegate callbacks, not from `data(for:)`, which would buffer a
///   2 GB response before anyone could object. A declared `Content-Length`
///   over the limit is refused before the first byte, and a body that grows
///   past it cancels the task at once; the excess is never kept. (Bytes are
///   counted after the system has undone `Content-Encoding`, so a
///   compression bomb is stopped too.)
/// - **Cancellation.** Cancelling the calling task cancels the data task, and
///   the call ends with `CancellationError`, not with `URLError.cancelled`.
/// - **No redirects followed.** A 3xx comes back as the response, as the
///   protocol asks of a transport, and ``HTTPClient`` follows it under rules
///   it owns (design/19). URL loading's own following kept only the headers
///   it knew to be credentials from another host, compared hosts but not
///   schemes or ports, and on Linux let an `https` request continue over
///   `http`.
/// - **One delegate, the session's.** The session the transport makes has a
///   delegate of its own that hands each task's callbacks to that task's
///   collector, by task identifier, on every platform.
///   swift-corelibs-foundation never calls a task's own delegate
///   (`URLSessionTask.delegate`), so a transport that relied on one waited
///   on Linux for a response that had arrived; and a session someone else
///   made cannot take this delegate, which is why there is no initializer
///   for one.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    /// The session's delegate.
    let transfers: Transfers
    private let streamBufferBytes: Int

    /// A transport on a new session made from `configuration`: its cache,
    /// cookies, proxies and timeouts are the configuration's, and so is
    /// everything a caller sets on it that is about the network rather than
    /// the request: `waitsForConnectivity`, `allowsExpensiveNetworkAccess`,
    /// `allowsConstrainedNetworkAccess`, and `timeoutIntervalForRequest`
    /// (which, as the time allowed between two packets, is also how long a
    /// streamed body may stall before it fails with `URLError.timedOut`).
    ///
    /// - Parameters:
    ///   - configuration: The session's configuration.
    ///   - streamBufferBytes: The most body bytes a streamed response holds
    ///     for a consumer that lags. Past it the data task is suspended; it
    ///     resumes when a quarter of this is left. A transfer can overshoot it
    ///     by what the system had already read, so it is a bound of the order
    ///     of this size, not an exact one. ``init(configuration:)`` uses 4 MiB.
    public init(configuration: URLSessionConfiguration, streamBufferBytes: Int) {
        precondition(streamBufferBytes > 0, "a stream needs room for at least one byte")
        let transfers = Transfers()
        session = URLSession(configuration: configuration, delegate: transfers, delegateQueue: nil)
        self.transfers = transfers
        self.streamBufferBytes = streamBufferBytes
    }

    /// A transport on a new session made from `configuration`, with a stream
    /// buffer of 4 MiB (see ``init(configuration:streamBufferBytes:)``).
    public convenience init(configuration: URLSessionConfiguration = .default) {
        self.init(configuration: configuration, streamBufferBytes: 4 << 20)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    private static func urlRequest(for request: HTTPRequest) throws -> URLRequest {
        guard let url = request.url else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for field in request.headers { urlRequest.addValue(field.value, forHTTPHeaderField: field.name) }
        urlRequest.httpBody = request.body.map { Data($0) }
        return urlRequest
    }

    /// The head as soon as it arrives, and the body as a stream with
    /// backpressure; see the class's notes. A declared `Content-Length` over
    /// the limit is refused before the first byte, a body that passes the
    /// limit ends the stream with ``HTTPTransportError/responseTooLarge(limit:)``
    /// having cancelled the task, and the data task is cancelled when the
    /// stream is cancelled or dropped, or when the task reading it is.
    public func stream(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPStreamedResponse {
        let urlRequest = try Self.urlRequest(for: request)
        let transfer = StreamTransfer(limit: maxResponseBytes, bufferLimit: streamBufferBytes, statistics: transfers.streams)
        let task = session.dataTask(with: urlRequest)
        transfer.attach(task)
        transfers.register(transfer, for: task)
        let head: HTTPURLResponse
        do {
            head = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, any Error>) in
                    transfer.awaitHead(continuation)
                    task.resume()
                }
            } onCancel: {
                transfer.abandon()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        var headers = HTTPHeaders()
        for (name, value) in head.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers.add(name, value) }
        }
        let body = HTTPBodyStream(next: { try await transfer.next() }, cancel: { transfer.abandon() })
        return HTTPStreamedResponse(status: head.statusCode, headers: headers, body: body)
    }

    public func send(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPResponse {
        let urlRequest = try Self.urlRequest(for: request)

        let transfer = Transfer(limit: maxResponseBytes)
        let task = session.dataTask(with: urlRequest)
        transfers.register(transfer, for: task)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                    transfer.begin(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

/// What the session's delegate hands one task's callbacks to.
protocol TransferSink: AnyObject, Sendable {
    /// The response head has arrived. `false` refuses it, and the task is
    /// cancelled before a byte moves.
    func receive(_ response: URLResponse) -> Bool
    /// Bytes have arrived. `false` means stop: the task is cancelled.
    func receive(_ data: Data) -> Bool
    /// The task is over; `error` is `nil` if it finished.
    func complete(error: (any Error)?)
}

/// The session's delegate: hands each callback to the ``TransferSink``
/// registered for its task, and forgets the sink when the task completes.
/// Task identifiers are unique within a session.
final class Transfers: NSObject, URLSessionDataDelegate, Sendable {
    private let byTask = Mutex<[Int: any TransferSink]>([:])
    /// What streamed transfers did, which the tests read: how much a lagging
    /// consumer made them hold, and how often they stopped the system reading.
    let streams = StreamStatistics()

    /// Routes `task`'s callbacks to `transfer`; called before the task resumes.
    func register(_ transfer: any TransferSink, for task: URLSessionTask) {
        byTask.withLock { $0[task.taskIdentifier] = transfer }
    }

    private func transfer(for task: URLSessionTask) -> (any TransferSink)? {
        byTask.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let allowed = transfer(for: dataTask)?.receive(response) ?? false
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let withinLimit = transfer(for: dataTask)?.receive(data) ?? false
        if !withinLimit { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // `nil` declines the redirect: the 3xx and its body are the response.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let transfer = byTask.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        transfer?.complete(error: error)
    }
}

/// Collects one task's response, enforcing the byte limit as bytes arrive.
final class Transfer: TransferSink {
    private struct State {
        var continuation: CheckedContinuation<HTTPResponse, any Error>?
        var response: HTTPURLResponse?
        var body = ByteBudget()
    }

    private let limit: Int
    private let state: Mutex<State>

    init(limit: Int) {
        self.limit = limit
        state = Mutex(State(body: ByteBudget(limit: limit)))
    }

    func begin(_ continuation: CheckedContinuation<HTTPResponse, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Keeps the response's head. Returns `false` if the length it declares
    /// is already over the limit: that settles it before a byte moves.
    func receive(_ response: URLResponse) -> Bool {
        state.withLock { state -> Bool in
            state.response = response as? HTTPURLResponse
            return state.body.declare(length: response.expectedContentLength)
        }
    }

    /// Keeps what fits of `data`. Returns `false` once the limit is passed,
    /// meaning the task is to be cancelled.
    func receive(_ data: Data) -> Bool {
        state.withLock { $0.body.append([UInt8](data)) }
    }

    func complete(error: (any Error)?) {
        let (continuation, response, body) = state.withLock { state -> (CheckedContinuation<HTTPResponse, any Error>?, HTTPURLResponse?, ByteBudget) in
            defer { state.continuation = nil }
            return (state.continuation, state.response, state.body)
        }
        guard let continuation else { return }
        if body.exceeded {
            continuation.resume(throwing: HTTPTransportError.responseTooLarge(limit: limit))
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response {
            var headers = HTTPHeaders()
            for (name, value) in response.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers.add(name, value) }
            }
            continuation.resume(returning: HTTPResponse(status: response.statusCode, headers: headers, body: body.bytes))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

/// Bytes collected up to a limit, and whether more were offered.
///
/// The whole of the limit logic, apart from the session: past the limit
/// nothing more is kept, and `exceeded` is permanent.
struct ByteBudget: Sendable {
    let limit: Int
    private(set) var bytes: [UInt8] = []
    private(set) var exceeded = false

    init(limit: Int = .max) {
        self.limit = limit
    }

    /// Notes the length a server declared (negative when unknown). Returns
    /// `false` if it already exceeds the limit.
    mutating func declare(length: Int64) -> Bool {
        if length > Int64(limit) { exceeded = true }
        return !exceeded
    }

    /// Keeps as much of `chunk` as fits. Returns `false` once the limit has
    /// been passed, meaning the transfer should stop.
    mutating func append(_ chunk: [UInt8]) -> Bool {
        guard !exceeded else { return false }
        let room = limit - bytes.count
        if chunk.count > room {
            bytes.append(contentsOf: chunk.prefix(room))
            exceeded = true
            return false
        }
        bytes.append(contentsOf: chunk)
        return true
    }
}
