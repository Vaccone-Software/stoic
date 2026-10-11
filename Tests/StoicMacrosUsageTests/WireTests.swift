#if STOIC_MACROS
import Foundation
import StoicJSON
import StoicMacros
import StoicSchema
import StoicSchemaTesting
import Testing

/// An API model that holds Foundation's types, in every spelling.
@Schema(unknownKeys: .reject)
struct Event: Equatable {
    var id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    /// When it was made.
    var created: Date = Date(timeIntervalSince1970: 0)
    @DateFormat(.epochSeconds) var seen: Date = Date(timeIntervalSince1970: 0)
    @DateFormat(.epochMilliseconds) var clicks: [Date] = []
    var home: URL = URL(string: "https://example.com")!
    @URLFormat(.relative) var link: URL? = nil
    var blob: Data = Data()
    @DataFormat(.base64url) var tokens: [String: Data] = [:]
    @Range(0...100) @MultipleOf(0.5) var discount: Decimal = 0
    var prices: [Decimal] = []
}

extension Event {
    static let byHand = Schema.object(
        Event.self, default: Event(), unknownKeys: .reject, doc: "An API model that holds Foundation's types, in every spelling."
    ) {
        Field("id", \.id, .uuid)
        Field("created", \.created, .date(), doc: "When it was made.")
        Field("seen", \.seen, .date(.epochSeconds))
        Field("clicks", \.clicks, .array(of: .date(.epochMilliseconds)))
        Field("home", \.home, .url())
        Field("link", \.link, .optional(.url(.relative)))
        Field("blob", \.blob, .data())
        Field("tokens", \.tokens, .dictionary(of: .data(.base64url)))
        Field("discount", \.discount, .decimal(.range(0...100), .multipleOf(0.5)))
        Field("prices", \.prices, .array(of: .decimal()))
    }
}

@Suite("@Schema on an API model")
struct WireModelTests {
    @Test func foundationTypesAreWrittenAsAHumanWould() {
        expectEquivalent(Event.schema, Event.byHand)
    }

    @Test func everyIssueIsReported() {
        let decoded = Event.schema.decode([
            "created": "2024-02-30T00:00:00Z", "seen": "yesterday", "home": "/relative", "id": "nope",
            "discount": 101, "prices": ["1,5", 2],
        ])
        #expect(
            decoded.issues.map { "\($0.path) \($0.code)" }.sorted() == [
                "$.created invalid_format", "$.discount out_of_range", "$.home invalid_format", "$.id invalid_format",
                "$.prices[0] type_mismatch", "$.seen type_mismatch",
            ])
    }

    @Test func theValuesAreTheOnesSent() {
        let decoded = Event.schema.decode([
            "seen": 1_714_566_600, "clicks": [1_714_566_600_123], "link": "../up", "tokens": ["a": "-_-_"],
            "prices": [19.99],
        ])
        #expect(decoded.value?.seen == Date(timeIntervalSince1970: 1_714_566_600))
        #expect(decoded.value?.clicks == [Date(timeIntervalSince1970: 1_714_566_600.123)])
        #expect(decoded.value?.link?.absoluteString == "../up")
        #expect(decoded.value?.tokens["a"] == Data([0xFB, 0xFF, 0xBF]))
        #expect(decoded.value?.prices == [Decimal(string: "19.99")!])
    }

    @Test func theSuiteIsClean() {
        let report = expectSchemaSuite(Event.schema, seed: 5, cases: 150)
        #expect(report.isClean, "\(report)")
    }
}
#endif
