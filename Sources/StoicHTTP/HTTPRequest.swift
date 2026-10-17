public import Foundation
public import Stoic
public import StoicJSON

/// A request, before the client has decided where it goes.
///
/// A request names a *path* (resolved against the client's base URL) or an
/// absolute URL; a query as items, so nothing is concatenated or escaped by
/// hand; headers; a body of bytes; and, for a request that is not safe to
/// repeat, the `IdempotencyKey` that makes it so.
///
///     let order = HTTPRequest.post("/orders", json: order.encoded)
///     try await api.send(order, idempotencyKey: order.key)
public struct HTTPRequest: Sendable, Hashable, CustomStringConvertible {
    /// Where the request goes.
    public enum Target: Sendable, Hashable {
        /// A path, joined to the client's base URL. Not percent-encoded: write
        /// `/files/a b`, and the client encodes it.
        case path(String)
        /// An absolute URL. The client's default headers are not sent to a
        /// host other than its base URL's.
        case url(URL)
    }

    public var method: HTTPMethod
    public var target: Target
    /// Appended to any query already in the target.
    public var query: [URLQueryItem]
    public var headers: HTTPHeaders
    public var body: [UInt8]?

    /// The key that lets a server recognise a repeat. With one, a `POST` or
    /// `PATCH` is retried; every attempt sends it, unchanged, as the
    /// `Idempotency-Key` header.
    public var idempotencyKey: IdempotencyKey?

    public init(
        method: HTTPMethod,
        target: Target,
        query: [URLQueryItem] = [],
        headers: HTTPHeaders = [:],
        body: [UInt8]? = nil,
        idempotencyKey: IdempotencyKey? = nil
    ) {
        self.method = method
        self.target = target
        self.query = query
        self.headers = headers
        self.body = body
        self.idempotencyKey = idempotencyKey
    }

    /// Whether this request may be sent again after a failure whose outcome
    /// on the server is unknown: its method is idempotent, or it carries a
    /// key (given as the property, or already set as an `Idempotency-Key`
    /// header).
    public var isSafeToRepeat: Bool {
        method.isIdempotent || idempotencyKey != nil || headers.contains(HTTPRequest.idempotencyKeyHeader)
    }

    /// The header an ``idempotencyKey`` is sent in.
    public static let idempotencyKeyHeader = "Idempotency-Key"

    /// The absolute URL with the query applied, or `nil` for a path that has
    /// not been resolved against a base URL yet.
    public var url: URL? {
        guard case .url(let url) = target else { return nil }
        guard !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + query
        return components.url ?? url
    }

    /// The method and path, without the query, the headers or the body:
    /// the part of a request that may appear in a log.
    public var description: String {
        switch target {
        case .path(let path): "\(method) \(path)"
        case .url(let url): "\(method) \(url.host ?? "")\(url.path)"
        }
    }

    // MARK: Builders

    public static func get(_ path: String, query: [URLQueryItem] = [], headers: HTTPHeaders = [:]) -> HTTPRequest {
        HTTPRequest(method: .get, target: .path(path), query: query, headers: headers)
    }

    public static func get(_ url: URL, query: [URLQueryItem] = [], headers: HTTPHeaders = [:]) -> HTTPRequest {
        HTTPRequest(method: .get, target: .url(url), query: query, headers: headers)
    }

    public static func head(_ path: String, query: [URLQueryItem] = [], headers: HTTPHeaders = [:]) -> HTTPRequest {
        HTTPRequest(method: .head, target: .path(path), query: query, headers: headers)
    }

    public static func delete(_ path: String, query: [URLQueryItem] = [], headers: HTTPHeaders = [:]) -> HTTPRequest {
        HTTPRequest(method: .delete, target: .path(path), query: query, headers: headers)
    }

    /// A `POST` with a JSON body (`Content-Type: application/json`).
    public static func post(_ path: String, json: JSONValue, query: [URLQueryItem] = [], headers: HTTPHeaders = [:]) -> HTTPRequest {
        sending(.post, path, json: json, query: query, headers: headers)
    }

    /// A `POST` with a body of bytes; give the `contentType` the server expects.
    public static func post(
        _ path: String, body: [UInt8], contentType: String, query: [URLQueryItem] = [], headers: HTTPHeaders = [:]
    ) -> HTTPRequest {
        sending(.post, path, body: body, contentType: contentType, query: query, headers: headers)
    }

    /// A `PUT` with a JSON body.
    public static func put(_ path: String, json: JSONValue, query: [URLQueryItem] = [], headers: HTTPHeaders = [:]) -> HTTPRequest {
        sending(.put, path, json: json, query: query, headers: headers)
    }

    /// A `PATCH` with a JSON body.
    public static func patch(_ path: String, json: JSONValue, query: [URLQueryItem] = [], headers: HTTPHeaders = [:]) -> HTTPRequest {
        sending(.patch, path, json: json, query: query, headers: headers)
    }

    /// This request with `key` as its idempotency key.
    public func keyed(_ key: IdempotencyKey) -> HTTPRequest {
        var copy = self
        copy.idempotencyKey = key
        return copy
    }

    private static func sending(
        _ method: HTTPMethod, _ path: String, json: JSONValue, query: [URLQueryItem], headers: HTTPHeaders
    ) -> HTTPRequest {
        sending(method, path, body: json.encoded(), contentType: "application/json", query: query, headers: headers)
    }

    private static func sending(
        _ method: HTTPMethod, _ path: String, body: [UInt8], contentType: String, query: [URLQueryItem], headers: HTTPHeaders
    ) -> HTTPRequest {
        var headers = headers
        if !headers.contains("Content-Type") { headers["Content-Type"] = contentType }
        return HTTPRequest(method: method, target: .path(path), query: query, headers: headers, body: body)
    }
}
