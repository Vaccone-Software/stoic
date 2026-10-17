/// What the server answered: a status, headers and the body's bytes.
///
/// The client returns only responses whose status is a success (2xx); any
/// other status is an ``HTTPError/status(_:excerpt:retryAfter:keyed:attempts:)``.
/// A transport returns every response it receives, whatever its status.
public struct HTTPResponse: Sendable, Hashable, CustomStringConvertible {
    public var status: Int
    public var headers: HTTPHeaders
    public var body: [UInt8]

    public init(status: Int, headers: HTTPHeaders = [:], body: [UInt8] = []) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Whether the status is 2xx.
    public var isSuccess: Bool { (200..<300).contains(status) }

    /// The body as UTF-8 text; invalid sequences become U+FFFD.
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// The status and the body's size. Neither the body nor the headers, so
    /// a response printed in a log leaks nothing.
    public var description: String { "HTTP \(status) (\(body.count) bytes)" }
}
