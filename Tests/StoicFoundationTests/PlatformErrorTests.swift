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

final class SendableCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
