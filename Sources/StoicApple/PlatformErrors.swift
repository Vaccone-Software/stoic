public import Foundation
public import Stoic

// Platform errors that classify themselves for retry.
//
// Without this, `retry`'s `.standard` classifier treats every URLError as
// worth retrying — including a malformed URL or a rejected certificate,
// which will fail the same way every time — and `.transientOnly` treats
// none of them as transient. Importing StoicApple makes the common
// Foundation and POSIX errors `Retryable`, so both classifiers make the
// right call without each app writing the same table.

extension URLError: Retryable {
    public var retryDecision: RetryDecision {
        switch code {
        // The network or the host is briefly unavailable.
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
             .backgroundSessionWasDisconnected, .badServerResponse, .callIsActive,
             .zeroByteResource, .cannotLoadFromNetwork:
            return .retry
        // The request itself is wrong, or the user or policy said no:
        // the same request will fail the same way.
        case .badURL, .unsupportedURL, .userAuthenticationRequired, .userCancelledAuthentication,
             .cancelled, .cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse,
             .fileDoesNotExist, .fileIsDirectory, .noPermissionsToReadFile, .dataLengthExceedsMaximum,
             .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
             .dataNotAllowed, .internationalRoamingOff, .redirectToNonExistentLocation,
             .httpTooManyRedirects, .requestBodyStreamExhausted:
            return .stop
        default:
            return .retry
        }
    }
}

extension POSIXError: Retryable {
    public var retryDecision: RetryDecision {
        switch code {
        case .EINTR, .EAGAIN, .ETIMEDOUT, .ECONNRESET, .ECONNREFUSED, .ECONNABORTED,
             .ENETDOWN, .ENETUNREACH, .ENETRESET, .EHOSTDOWN, .EHOSTUNREACH, .EPIPE, .EBUSY, .ENOBUFS:
            return .retry
        default:
            // Missing files, permissions, invalid arguments, a full or
            // read-only disk: retrying cannot change them.
            return .stop
        }
    }
}

extension CocoaError: Retryable {
    public var retryDecision: RetryDecision {
        switch code {
        case .fileLocking, .ubiquitousFileUnavailable, .ubiquitousFileNotUploadedDueToQuota:
            return .retry
        default:
            return .stop
        }
    }
}

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
