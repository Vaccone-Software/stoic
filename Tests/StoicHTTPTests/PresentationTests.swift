import Foundation
import Stoic
import StoicHTTP
import StoicSchema
import StoicTesting
import Testing

/// `HTTPError: Presentable` (design/31): every case, as a person reads it.
@Suite("HTTP errors, presented", .stoic())
struct HTTPPresentationTests {
    static let now = TestClock.wallClockStart

    static func status(_ code: Int, retryAfter: Duration? = nil) -> HTTPError {
        .status(code, excerpt: "ana@example.com was not found", retryAfter: retryAfter, attempts: 1)
    }

    static let cases: [(error: HTTPError, key: String, recovery: Recovery)] = [
        (status(401), "stoic.http.sign_in", .signInAgain),
        (status(403), "stoic.permission.denied", .nothing),
        (status(404), "stoic.lifecycle.gone", .nothing),
        (status(410), "stoic.lifecycle.gone", .nothing),
        (status(409), "stoic.lifecycle.conflict", .tryAgain),
        (status(400), "stoic.http.invalid", .changeInput(fields: [])),
        (status(422), "stoic.http.invalid", .changeInput(fields: [])),
        (status(429, retryAfter: .seconds(20)), "stoic.busy", .wait(until: now + .seconds(20))),
        (status(429), "stoic.busy", .wait(until: nil)),
        (status(503, retryAfter: .seconds(120)), "stoic.unavailable", .wait(until: now + .seconds(120))),
        (status(500), "stoic.unavailable", .wait(until: nil)),
        (status(418), "stoic.failure.ours", .contactSupport),
        (.transport(.notConnectedToInternet, attempts: 1), "stoic.offline", .wait(until: nil)),
        (.transport(.timedOut, attempts: 2), "stoic.slow", .tryAgain),
        (.transport(.cannotFindHost, attempts: 1), "stoic.unreachable", .tryAgain),
        (.transport(.secureConnectionFailed, attempts: 1), "stoic.unreachable", .tryAgain),
        (.timedOut(attempt: 2), "stoic.slow", .tryAgain),
        (.responseTooLarge(limit: 1_024, attempts: 1), "stoic.failure.ours", .contactSupport),
        (.rejected(Rejection(.circuitOpen), attempts: 0), "stoic.unavailable", .wait(until: nil)),
        (.reauthenticationFailed(status: 401, attempts: 1), "stoic.http.sign_in", .signInAgain),
        (.redirectRefused(.downgrade, status: 301, location: "http://example.com", attempts: 1), "stoic.failure.ours", .contactSupport),
        (.authenticationFailed(HTTPAuthenticationError(scheme: "attest", code: "invalid", retryDecision: .stop), attempts: 0),
         "stoic.failure.ours", .contactSupport),
        (.authenticationFailed(HTTPAuthenticationError(scheme: "attest", code: "busy", retryDecision: .retry), attempts: 0),
         "stoic.unavailable", .wait(until: nil)),
    ]

    @Test func everyCaseReadsAsItsRow() throws {
        for (error, key, recovery) in Self.cases {
            let presented = try #require(error.presented(), "\(error)")
            #expect(presented.message.key == key, "\(error)")
            #expect(presented.recovery == recovery, "\(error)")
            #expect(presented.isClassified)
            #expect(HTTPError.wordings.contains(presented.message), "\(key) is listed for a translation catalog")
            #expect(!presented.message.description.contains("ana@example.com"), "a body's excerpt is never shown")
        }
    }

    @Test func aDecodingFailureIsADisagreementBetweenAppAndServer() throws {
        let presented = try #require(HTTPError.decoding(ValidationFailure(issues: []), attempts: 1).presented())
        #expect(presented.message.key == "stoic.failure.ours")
    }
}
