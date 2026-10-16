public import Foundation
#if canImport(FoundationNetworking)
// URLSession and HTTPURLResponse live here on Linux.
public import FoundationNetworking
#endif
public import Stoic

// HTTP status semantics for retry: which statuses are worth repeating, and
// what a `Retry-After` header asks for. The client uses them for every
// response; they are public so code that talks HTTP some other way makes
// the same decisions.

/// How an HTTP response status should be treated, following the semantics
/// of RFC 9110 and the common practice of the large APIs.
public struct HTTPRetry: Sendable {
    /// The decision for a response with `status`, honouring `Retry-After`
    /// (seconds, or an HTTP date) when the server sent one.
    ///
    /// - 408, 425, 429, 500, 502, 503 and 504 are worth retrying; 429 and 503
    ///   use the server's `Retry-After` when present.
    /// - Every other 4xx is the request's fault: stop.
    /// - Other 5xx (501 Not Implemented, 505, …) will not change: stop.
    /// - Anything else is not a failure: stop (there is nothing to retry).
    public static func decision(status: Int, retryAfter: String? = nil, now: Date = Date()) -> RetryDecision {
        switch status {
        case 408, 425, 500, 502, 504:
            return .retry
        case 429, 503:
            if let delay = retryAfterDelay(retryAfter, now: now) { return .retryAfter(delay) }
            return .retry
        default:
            return .stop
        }
    }

    /// Parses a `Retry-After` header: a number of seconds, or an HTTP date in
    /// any of the three formats RFC 9110 §5.6.7 requires a recipient to accept
    /// (IMF-fixdate, obsolete RFC 850, and asctime). A date in the past is a
    /// delay of zero; anything else unparseable is `nil`.
    public static func retryAfterDelay(_ header: String?, now: Date = Date()) -> Duration? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Int(header), seconds >= 0 {
            return .seconds(seconds)
        }
        guard let date = HTTPDate.parse(header, now: now) else { return nil }
        let interval = max(0, date.timeIntervalSince(now))
        return .milliseconds(Int64((interval * 1000).rounded()))
    }
}

/// An HTTP response that failed, as an error that classifies itself.
public struct HTTPStatusError: Error, Retryable, CustomStringConvertible {
    public let status: Int
    public let retryAfter: String?

    public init(status: Int, retryAfter: String? = nil) {
        self.status = status
        self.retryAfter = retryAfter
    }

    /// The error for `response`, or `nil` if its status is a success.
    public init?(_ response: HTTPURLResponse) {
        guard !(200..<400).contains(response.statusCode) else { return nil }
        self.init(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
    }

    public var retryDecision: RetryDecision {
        HTTPRetry.decision(status: status, retryAfter: retryAfter)
    }

    public var description: String { "HTTP \(status)" }
}
