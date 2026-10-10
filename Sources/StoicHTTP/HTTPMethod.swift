/// An HTTP request method, with what RFC 9110 says about repeating it.
///
/// Whether a request may be sent again is a property of its method, and the
/// client's retry rule is built on exactly these two flags: a *safe* method
/// changes nothing on the server, an *idempotent* one has the same effect
/// when repeated. `POST` and `PATCH` are neither, which is why they are only
/// retried when the caller supplies an ``HTTPRequest/idempotencyKey``.
public struct HTTPMethod: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The method's name, upper case.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static let get: HTTPMethod = "GET"
    public static let head: HTTPMethod = "HEAD"
    public static let options: HTTPMethod = "OPTIONS"
    public static let trace: HTTPMethod = "TRACE"
    public static let put: HTTPMethod = "PUT"
    public static let delete: HTTPMethod = "DELETE"
    public static let post: HTTPMethod = "POST"
    public static let patch: HTTPMethod = "PATCH"

    /// Whether the method asks for information and changes nothing:
    /// `GET`, `HEAD`, `OPTIONS` and `TRACE`.
    public var isSafe: Bool {
        self == .get || self == .head || self == .options || self == .trace
    }

    /// Whether repeating the request has the same effect as sending it once:
    /// every safe method, `PUT` and `DELETE`. A method this type does not
    /// know is not assumed to be idempotent.
    public var isIdempotent: Bool {
        isSafe || self == .put || self == .delete
    }

    public var description: String { rawValue }
}
