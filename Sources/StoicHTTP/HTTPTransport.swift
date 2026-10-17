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
    ///     the excess first.
    /// - Throws: `URLError` for a network failure (the client classifies it
    ///   by code), ``HTTPTransportError``, or `CancellationError`.
    func send(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPResponse
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
