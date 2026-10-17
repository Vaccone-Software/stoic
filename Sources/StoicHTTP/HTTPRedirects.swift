internal import Foundation

/// Where a URL's requests go, for deciding what may follow a request there:
/// the scheme, the host and the port, with the port the scheme implies when
/// the URL names none (`https://a.com` and `https://a.com:443` are one
/// origin; `http://a.com` and `https://a.com:8443` are each another).
struct Origin: Hashable, Sendable {
    var scheme: String
    var host: String
    var port: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        guard let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }
}

/// How the client follows a redirect: the rules in one place, apart from the
/// sending (design/19).
///
/// The transport follows none, so these are the rules on every platform,
/// whatever the system's URL loading would have done:
///
/// - **Which.** 301, 302, 303, 307 and 308 with a `Location` are followed.
///   Any other 3xx (a 304, a 300) and a redirect with no `Location` are
///   answers, and fail as `.status` like any other non-2xx.
/// - **The method** (RFC 9110 §15.4, as browsers do): a `POST` answered 301 or
///   302, and anything but `GET` or `HEAD` answered 303, becomes a `GET`
///   without its body, its body headers or its idempotency key: what follows
///   is a new, safe request for the result. 307 and 308 keep the method and
///   the body, keyed or not: the server answered instead of acting, so
///   following is not a repeat, as for a `401` replay.
/// - **What crosses an origin.** Once a redirect leaves the request's origin,
///   only the headers that negotiate content and cannot hold a credential
///   go along (``crossOriginHeaders``); the idempotency key stays behind (it
///   names the operation to the server it was made for), and the client's
///   own headers never return to the chain, even if it comes back to the
///   base URL: a host the client merely followed must not steer it into
///   authenticated requests to paths of that host's choosing.
/// - **What is refused.** An `https` request redirected to `http` (anything
///   in it would travel in the clear, and only Apple's App Transport
///   Security stopped it before), a `Location` that is not an `http` or
///   `https` URL, and a redirect past ``HTTPPolicy/maxRedirects``.
enum Redirects {
    /// The statuses the client follows.
    static let statuses: Set<Int> = [301, 302, 303, 307, 308]

    /// The request headers that go along when a redirect changes origin,
    /// lower case. Each negotiates the content or describes the body, and
    /// none can carry a credential; every other header, custom ones such as
    /// `X-API-Key` included, stays with the origin it was meant for.
    ///
    /// `If-Range` goes with `Range`, which a resumed download sends to an API
    /// that redirects to a CDN: a `Range` that arrives without the validator
    /// it was made for lets the new server splice a changed file onto the
    /// bytes already held. A validator is an `ETag` or a date the server
    /// itself sent; it names no one.
    static let crossOriginHeaders: Set<String> = [
        "accept", "accept-encoding", "accept-language", "user-agent", "range", "if-range",
        "content-type", "content-encoding", "content-language",
    ]

    /// The headers that describe a body, dropped with it (the Fetch
    /// standard's request-body header names).
    static let bodyHeaders: Set<String> = [
        "content-type", "content-length", "content-encoding", "content-language", "content-location",
    ]

    /// Whether `response` is a redirect the client follows, or refuses to:
    /// a redirect status with a `Location`.
    static func isRedirect(_ response: HTTPResponse) -> Bool {
        statuses.contains(response.status) && response.headers["Location"] != nil
    }

    /// The next request of a chain.
    struct Hop {
        /// The request as a caller would have written it: an absolute URL,
        /// the headers that survive, the body if it is kept, the key if it is.
        var request: HTTPRequest
        /// Whether the client's own headers may go with it: the chain has
        /// never left the base URL's origin, and does not now.
        var clientHeaders: Bool
        /// Whether this hop left the origin of the request before it.
        var changesOrigin: Bool
    }

    enum Next {
        case follow(Hop)
        case refuse(HTTPError.RedirectRefusal, location: String)
    }

    /// What follows `response`, a redirect (``isRedirect(_:)``) to `prepared`,
    /// after `followed` redirects already.
    static func next(after response: HTTPResponse, to prepared: PreparedRequest, followed: Int, limit: Int) -> Next {
        let location = response.headers["Location"] ?? ""
        guard followed < limit else { return .refuse(.limit, location: location) }
        guard let current = prepared.request.url,
              let target = URL(string: location, relativeTo: current)?.absoluteURL,
              let to = Origin(target), to.scheme == "http" || to.scheme == "https", !to.host.isEmpty,
              let from = Origin(current) else {
            return .refuse(.invalidLocation, location: location)
        }
        if from.scheme == "https", to.scheme == "http" { return .refuse(.downgrade, location: location) }

        let source = prepared.source
        var method = source.method
        var headers = source.headers
        var body = source.body
        var key = prepared.sourceKey ?? source.idempotencyKey
        let status = response.status
        if (status == 303 && method != .get && method != .head) || ((status == 301 || status == 302) && method == .post) {
            method = .get
            body = nil
            key = nil
            headers = HTTPHeaders(headers.fields.filter {
                let name = $0.name.lowercased()
                return !bodyHeaders.contains(name) && name != HTTPRequest.idempotencyKeyHeader.lowercased()
            })
        }
        let changesOrigin = to != from
        if changesOrigin {
            key = nil
            headers = HTTPHeaders(headers.fields.filter { crossOriginHeaders.contains($0.name.lowercased()) })
        }
        let request = HTTPRequest(method: method, target: .url(target), headers: headers, body: body, idempotencyKey: key)
        return .follow(Hop(request: request, clientHeaders: prepared.carriesClientHeaders && !changesOrigin, changesOrigin: changesOrigin))
    }
}
