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
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let ownsSession: Bool

    /// A transport on a new session made from `configuration`.
    public init(configuration: URLSessionConfiguration = .default) {
        session = URLSession(configuration: configuration)
        ownsSession = true
    }

    /// A transport on a session you manage. The session must not have a
    /// delegate that expects to see this transport's tasks: each task has its
    /// own.
    public init(session: URLSession) {
        self.session = session
        ownsSession = false
    }

    deinit {
        if ownsSession { session.finishTasksAndInvalidate() }
    }

    public func send(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPResponse {
        guard let url = request.url else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for field in request.headers { urlRequest.addValue(field.value, forHTTPHeaderField: field.name) }
        urlRequest.httpBody = request.body.map { Data($0) }

        let transfer = Transfer(limit: maxResponseBytes)
        let task = session.dataTask(with: urlRequest)
        task.delegate = transfer
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

/// Collects one task's response, enforcing the byte limit as bytes arrive.
final class Transfer: NSObject, URLSessionDataDelegate, Sendable {
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
        super.init()
    }

    func begin(_ continuation: CheckedContinuation<HTTPResponse, any Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let allowed = state.withLock { state -> Bool in
            state.response = response as? HTTPURLResponse
            // A length the server declares up front settles it before a byte moves.
            return state.body.declare(length: response.expectedContentLength)
        }
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let withinLimit = state.withLock { $0.body.append([UInt8](data)) }
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
