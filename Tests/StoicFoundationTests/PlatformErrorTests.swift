import Foundation
import Synchronization
import Stoic
import StoicFoundation
import StoicTesting
import Testing

@Suite("Platform errors")
struct PlatformErrorTests {
    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet])
    func transientURLErrorsRetry(_ code: URLError.Code) {
        #expect(URLError(code).retryDecision == .retry)
    }

    @Test(arguments: [URLError.Code.badURL, .serverCertificateUntrusted, .userAuthenticationRequired, .cannotParseResponse])
    func permanentURLErrorsStop(_ code: URLError.Code) {
        #expect(URLError(code).retryDecision == .stop)
    }

    @Test func posixErrorsSplitBetweenTransientAndPermanent() {
        #expect(POSIXError(.ECONNRESET).retryDecision == .retry)
        #expect(POSIXError(.ENOENT).retryDecision == .stop)
        #expect(POSIXError(.ENOSPC).retryDecision == .stop)
    }

    @Test func transientOnlyRetriesAURLTimeoutButNotABadURL() async throws {
        let attempts = SendableCounter()
        await #expect(throws: URLError.self) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.fixed(.seconds(1)).attempts(3), classify: .transientOnly) { _ throws(URLError) -> Int in
                    attempts.increment()
                    throw URLError(.timedOut)
                }
            }
        }
        #expect(attempts.value == 3)
        let bad = SendableCounter()
        await #expect(throws: URLError.self) {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await retry(.fixed(.seconds(1)).attempts(3)) { _ throws(URLError) -> Int in
                    bad.increment()
                    throw URLError(.badURL)
                }
            }
        }
        #expect(bad.value == 1)
    }
}

/// Which platform errors prove that nothing reached the backend (design/22,
/// Classification): only those that fail before a connection exists.
@Suite("Never reached the backend")
struct NeverReachedBackendTests {
    @Test(arguments: [
        (URLError.Code.cannotFindHost, "the host name did not resolve: nothing was sent"),
        (.dnsLookupFailed, "the lookup itself failed: nothing was sent"),
        (.cannotConnectToHost, "nothing accepted the connection: nothing was sent"),
        (.notConnectedToInternet, "there is no network at all: nothing was sent"),
    ])
    func urlErrorsThatFailBeforeAConnectionExist(_ code: URLError.Code, _ meaning: String) {
        #expect(URLError(code).neverReachedBackend, "\(meaning)")
    }

    @Test(arguments: [
        (URLError.Code.timedOut, "the request may have been sent and acted on before the timeout"),
        (.networkConnectionLost, "the connection was lost after it opened: the request may have arrived"),
        (.badServerResponse, "the server answered: it was reached"),
        (.secureConnectionFailed, "the TLS handshake failed after the connection opened"),
    ])
    func urlErrorsThatMayComeAfterSending(_ code: URLError.Code, _ meaning: String) {
        #expect(!URLError(code).neverReachedBackend, "\(meaning)")
    }

    @Test(arguments: [
        (POSIXError.Code.ECONNREFUSED, "the peer refused the connection: nothing was sent"),
        (.ENETUNREACH, "no route to the network: nothing was sent"),
        (.EHOSTUNREACH, "no route to the host: nothing was sent"),
    ])
    func posixErrorsThatFailBeforeAConnectionExist(_ code: POSIXError.Code, _ meaning: String) {
        #expect(POSIXError(code).neverReachedBackend, "\(meaning)")
    }

    @Test(arguments: [
        (POSIXError.Code.ECONNRESET, "the peer reset an open connection: bytes may have arrived"),
        (.ETIMEDOUT, "the connection timed out, possibly after sending"),
        (.EPIPE, "the write failed on a connection that was open"),
    ])
    func posixErrorsThatMayComeAfterSending(_ code: POSIXError.Code, _ meaning: String) {
        #expect(!POSIXError(code).neverReachedBackend, "\(meaning)")
    }

    @Test func otherErrorsClaimNothing() {
        struct Plain: Error, Retryable { var retryDecision: RetryDecision { .retry } }
        #expect(!Plain().neverReachedBackend)
        #expect(!CocoaError(.fileLocking).neverReachedBackend)
    }
}

final class SendableCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
