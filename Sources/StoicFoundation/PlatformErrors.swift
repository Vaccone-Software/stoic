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
