/// Carries one request to a server and brings back its response.
///
/// The seam where tests replace the network: ``HTTPClient`` owns every
/// policy (retries, breaker, timeouts, redirects), and a transport owns
/// none. It makes exactly one HTTP exchange per call, returns the response
/// whatever its status, and ends promptly when its task is cancelled. It does
/// not follow a redirect: a 3xx is a response like any other, and the client
/// decides where, and with which headers, the request goes next.
///
/// A transport receives a request whose target is an absolute URL
/// (``HTTPRequest/url`` is non-`nil`), with the final headers, the
/// idempotency key included.
public protocol HTTPTransport: Sendable {
    /// Sends `request` and returns the response.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - maxResponseBytes: The most body bytes to read. A transport
    ///     that sees more stops reading, abandons the connection and throws
    ///     ``HTTPTransportError/responseTooLarge(limit:)`` — it does not buffer
    ///     the excess first. A declared length over the limit is refused
    ///     before the first byte when a body will be transferred; a response
    ///     to `HEAD`, and a `204` or `304`, are not refused for the length
    ///     they declare.
    /// - Throws: `URLError` for a network failure (the client classifies it
    ///   by code), ``HTTPTransportError``, or `CancellationError`.
    func send(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPResponse

    /// Sends `request` and returns as soon as the response head (the status
    /// and headers) has arrived, with the body to be read as a stream.
    ///
    /// For a body too large to hold. The same contract as ``send(_:maxResponseBytes:)``
    /// otherwise: one exchange, whatever the status, no redirect followed, and
    /// prompt when the calling task is cancelled.
    ///
    /// - Parameters:
    ///   - request: The request to send.
    ///   - maxResponseBytes: The most body bytes the stream may deliver. A
    ///     transport refuses a body whose declared length is over it before the
    ///     first byte, when a body will be transferred (this call throws
    ///     ``HTTPTransportError/responseTooLarge(limit:)``). A response to
    ///     `HEAD`, and a `204` or `304`, declare the size a `GET` would have
    ///     sent and are not refused for it. A stream that passes the limit
    ///     ends with the same error, having abandoned the connection; it does
    ///     not read the excess first.
    /// - Returns: The head, and the body. Cancelling the body's task, calling
    ///   ``HTTPBodyStream/cancel()`` or dropping it ends the exchange.
    /// - Throws: As ``send(_:maxResponseBytes:)``, for what happens before the
    ///   head arrives; what goes wrong afterwards is thrown by the body.
    ///
    /// The default sends the request with ``send(_:maxResponseBytes:)`` and
    /// yields the whole body as one chunk. That is right for a test
    /// transport, and wrong for anything else: nothing is streamed, and the
    /// body is in memory first. A transport that carries real bodies
    /// implements this itself (``URLSessionTransport`` does).
    func stream(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPStreamedResponse
}

extension HTTPTransport {
    public func stream(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPStreamedResponse {
        let response = try await send(request, maxResponseBytes: maxResponseBytes)
        return HTTPStreamedResponse(status: response.status, headers: response.headers, body: HTTPBodyStream(bytes: response.body))
    }
}

/// A failure a transport reports that is not a `URLError`.
public enum HTTPTransportError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The response body exceeded the limit, and the transfer was abandoned.
    case responseTooLarge(limit: Int)

    public var description: String {
        switch self {
        case .responseTooLarge(let limit): "response body larger than \(limit) bytes"
        }
    }
}
