import Foundation
import Stoic
import StoicHTTP
import Testing

@Suite("HTTP status semantics")
struct HTTPStatusSemanticsTests {
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

    // RFC 9110 §5.6.7's own example, in its three spellings.
    @Test(arguments: [
        "Sun, 06 Nov 1994 08:49:37 GMT",
        "Sunday, 06-Nov-94 08:49:37 GMT",
        "Sun Nov  6 08:49:37 1994",
    ])
    func retryAfterAcceptsEveryHTTPDateFormat(_ header: String) {
        let now = Date(timeIntervalSince1970: 784_111_777 - 90)   // 08:49:37 minus 90 seconds
        #expect(HTTPRetry.retryAfterDelay(header, now: now) == .seconds(90))
        #expect(HTTPRetry.decision(status: 503, retryAfter: header, now: now) == .retryAfter(.seconds(90)))
    }

    @Test func aDateInThePastIsNoDelayAndGarbageIsNone() {
        let now = Date(timeIntervalSince1970: 784_111_777 + 3600)
        #expect(HTTPRetry.retryAfterDelay("Sun, 06 Nov 1994 08:49:37 GMT", now: now) == .zero)
        for bad in ["", "soon", "Sun, 31 Feb 1994 08:49:37 GMT", "Sun, 06 Nov 1994 25:49:37 GMT",
                    "Sun, 06 Nov 1994 08:49:37 PST", "Fri, 06 Nov 1994 08:49:37", "Sunday, 06-Nov-1994 08:49:37 GMT",
                    "Sun Nov 6 08:49:37", "-5"] {
            #expect(HTTPRetry.retryAfterDelay(bad, now: now) == nil, "\(bad)")
        }
    }

    @Test func aTwoDigitYearMoreThanFiftyYearsAheadMeansThePastCentury() {
        // RFC 9110: "Sunday, 06-Nov-94" read in 2026 is 1994, not 2094 (68 years ahead).
        let now = Date(timeIntervalSince1970: 1_790_000_000)   // late 2026
        let past = HTTPRetry.retryAfterDelay("Sunday, 06-Nov-94 08:49:37 GMT", now: now)
        #expect(past == .zero)
        // And "40" is within 50 years ahead, so it is 2040: a long delay.
        let future = HTTPRetry.retryAfterDelay("Monday, 06-Nov-40 08:49:37 GMT", now: now)
        #expect((future ?? .zero) > .seconds(300_000_000))
    }
}
