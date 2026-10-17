public import Foundation
public import Stoic

// Platform errors that classify themselves for retry.
//
// Without this, `retry`'s `.standard` classifier treats every URLError as
// worth retrying — including a malformed URL or a rejected certificate,
// which will fail the same way every time — and `.transientOnly` treats
// none of them as transient. Linking StoicFoundation makes the common
// Foundation and POSIX errors `Retryable`, so both classifiers make the
// right call without each app writing the same table. StoicApple and
// StoicHTTP link it, so adopting either brings the table with it.

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

    /// True for the codes that fail before a connection exists: the host
    /// was not found, or nothing answered, or there is no network at all.
    /// Nothing was sent, so even an operation that is not safe to repeat
    /// may be tried again (design/22).
    public var neverReachedBackend: Bool {
        switch code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet:
            return true
        default:
            // A timeout, a lost connection or a bad response may come after
            // the request was sent: whether the server acted is unknown.
            return false
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

    /// True for a refused connection and an unreachable network or host:
    /// the connection never opened, so nothing was sent (design/22).
    public var neverReachedBackend: Bool {
        switch code {
        case .ECONNREFUSED, .ENETUNREACH, .EHOSTUNREACH:
            return true
        default:
            // A reset, an abort or a timeout can come after bytes were sent.
            return false
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

// On Apple platforms Foundation stores `URLError`, `POSIXError` and
// `CocoaError` in an `any Error` as their `NSError`: a protocol cast on it
// finds none of the conformances above (a real URLSession failure is an
// `NSURLError` too). The core asks an `NSError` for its Swift value, so the
// table applies on every platform. An `NSError` in any other domain is not
// one of these types, and classifies as it always did.
extension NSError: BridgedClassification {
    package var bridgedRetryable: (any Retryable)? {
        switch domain {
        case NSURLErrorDomain: URLError(_nsError: self)
        case NSPOSIXErrorDomain: POSIXError(_nsError: self)
        case NSCocoaErrorDomain: CocoaError(_nsError: self)
        default: nil
        }
    }
}
