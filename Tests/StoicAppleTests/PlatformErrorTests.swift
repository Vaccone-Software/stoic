import Foundation
import Synchronization
import Stoic
import StoicApple
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

    @Test func httpStatusesFollowTheirSemantics() {
        #expect(HTTPRetry.decision(status: 503) == .retry)
        #expect(HTTPRetry.decision(status: 429, retryAfter: "7") == .retryAfter(.seconds(7)))
        #expect(HTTPRetry.decision(status: 404) == .stop)
        #expect(HTTPRetry.decision(status: 501) == .stop)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = "Mon, 12 Jan 1970 13:47:00 GMT"   // 1_000_020
        #expect(HTTPRetry.retryAfterDelay(later, now: now) == .seconds(20))
        #expect(HTTPRetry.retryAfterDelay("soon") == nil)
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

final class SendableCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
