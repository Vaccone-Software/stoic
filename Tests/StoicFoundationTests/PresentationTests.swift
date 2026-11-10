import Foundation
@testable import Stoic
import StoicFoundation
import StoicTesting
import Testing

/// `String(localized:)` and `Presenter.foundation` (design/31).
@Suite("Presenting in Foundation", .stoic())
struct FoundationPresentationTests {
    static let utc = TimeZone(identifier: "UTC")
    static let english = Locale(identifier: "en_US")
    static let german = Locale(identifier: "de_DE")

    @Test func aTranslatedKeyReadsFromTheAppsStoicTable() {
        let wording = Presenter.standard.wordings.first { $0.key == "stoic.busy" }
        #expect(wording.map { String(localized: $0, bundle: .module) } == "Translated: too many requests.")
    }

    @Test(.failureMode("design/31", "a wording has no translation"))
    func aMissingKeyReadsAsItsDefaultTextWithItsArgumentsFormatted() {
        let wording = Wording("app.not-translated", default: "{count} places left.", table: "Stoic", arguments: ["count": .integer(1_234)])
        #expect(String(localized: wording, bundle: .module, locale: Self.english) == "1,234 places left.")
        #expect(String(localized: wording, bundle: .module, locale: Self.german) == "1.234 places left.")
        let noTable = Wording("app.not-translated", default: "Nothing here.")
        #expect(String(localized: noTable, bundle: .module) == "Nothing here.")
    }

    @Test func everyArgumentKindIsFormattedForTheLocale() throws {
        let moment = TestClock.wallClockStart + .seconds(9 * 3_600 + 30 * 60)
        let wording = Wording("test.arguments", default: "untranslated", table: "Stoic", arguments: [
            "count": .integer(1_234_567), "when": .moment(moment), "left": .duration(.seconds(5_400)), "name": .text("Ana"),
        ])
        let utc = try #require(Self.utc)
        let date = Date(timeIntervalSince1970: 1_767_225_600 + 9 * 3_600 + 30 * 60)
        for locale in [Self.english, Self.german] {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
            style.timeZone = utc
            let when = date.formatted(style)
            let left = Duration.seconds(5_400).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .wide).locale(locale))
            let count = 1_234_567.formatted(.number.locale(locale))
            let text = String(localized: wording, bundle: .module, locale: locale, timeZone: utc)
            #expect(text == "\(count) people, by \(when), within \(left), for Ana; {missing} stays.", "\(locale.identifier)")
        }
        let english = String(localized: wording, bundle: .module, locale: Self.english, timeZone: utc)
        let german = String(localized: wording, bundle: .module, locale: Self.german, timeZone: utc)
        #expect(english.hasPrefix("1,234,567 people"))
        #expect(german.hasPrefix("1.234.567 people"))
        #expect(english != german)
    }

    @Test func theFoundationPresentersWordingsAreAllInTheTable() {
        let missing = "\u{0}missing"
        for wording in Presenter.foundation.wordings {
            let found = Bundle.module.localizedString(forKey: wording.key, value: missing, table: wording.table)
            #expect(found != missing, "the Stoic table has no \(wording.key)")
        }
        #expect(Presenter.foundation.wordings.starts(with: Presenter.standard.wordings))
    }

    static let cases: [(error: any Error & Sendable, key: String, recovery: Recovery)] = [
        (URLError(.notConnectedToInternet), "stoic.offline", .wait(until: nil)),
        (URLError(.networkConnectionLost), "stoic.offline", .wait(until: nil)),
        (URLError(.dataNotAllowed), "stoic.offline", .wait(until: nil)),
        (URLError(.timedOut), "stoic.slow", .tryAgain),
        (URLError(.cannotFindHost), "stoic.unreachable", .tryAgain),
        (URLError(.cannotConnectToHost), "stoic.unreachable", .tryAgain),
        (URLError(.badURL), "stoic.failure", .contactSupport),
        (POSIXError(.ENOSPC), "stoic.disk_full", .nothing),
        (POSIXError(.ETIMEDOUT), "stoic.slow", .tryAgain),
        (POSIXError(.ECONNREFUSED), "stoic.unreachable", .tryAgain),
        (POSIXError(.EACCES), "stoic.failure", .contactSupport),
        (CocoaError(.fileWriteOutOfSpace), "stoic.disk_full", .nothing),
        (CocoaError(.fileNoSuchFile), "stoic.failure", .contactSupport),
    ]

    @Test func foundationsErrorsReadAsTheirRules() throws {
        try withAmbient({ $0.presenter = .foundation }) { () throws in
            for (error, key, recovery) in Self.cases {
                let presented = try #require(error.presented(), "\(error)")
                #expect(presented.message.key == key, "\(error)")
                #expect(presented.recovery == recovery, "\(error)")
                let inReport = try #require(Report(error).adding(Report.Frame("downloading")).presented())
                #expect(inReport.message.key == key, "\(error) in a Report")
            }
        }
    }

    /// On Apple platforms Foundation hands these over as their `NSError`.
    @Test func theRulesSeeAnErrorHeldAsItsNSError() throws {
        let bridged: [(any Error, String)] = [
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), "stoic.offline"),
            (URLError(.timedOut) as NSError, "stoic.slow"),
            (CocoaError(.fileWriteOutOfSpace) as NSError, "stoic.disk_full"),
        ]
        try withAmbient({ $0.presenter = .foundation }) { () throws in
            for (error, key) in bridged {
                #expect(try #require(error.presented()).message.key == key, "\(error)")
            }
        }
    }

    @Test func withoutTheRulesAnUnreachedCallStillSaysSo() throws {
        let error = OperationError<any Error>(
            stop: .failed(URLError(.badURL)), outcome: .notExecuted, last: URLError(.badURL), attempts: 1, safety: .idempotent,
            idempotencyKey: nil)
        #expect(try #require(error.presented()).message.key == "stoic.unreachable", "the operation's fallback")
        #expect(try #require(URLError(.notConnectedToInternet).presented()).message.key == "stoic.failure", "the standard presenter")
    }
}
