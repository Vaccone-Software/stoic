#if STOIC_MACROS
import Foundation
import Stoic
import StoicJSON
import StoicMacros
import StoicSchema
import StoicSchemaTesting
import StoicTesting
import Testing

/// A wire model: `id` and `name` must be there, `email` may be missing or
/// null, the rest has defaults.
@Schema(unknownKeys: .ignore)
struct Account: Equatable {
    /// The account number.
    var id: Int
    /// The display name.
    @Length(1...40) var name: String
    /// Where to write, if known.
    var email: String?
    /// When it was opened.
    @Key("created_at") var createdAt: Date
    /// Prepaid credit.
    @Range(0...100) var credit: Double = 0
    /// Free-form labels.
    var tags: [String] = []
    @Ignored var cache: [String: Int] = [:]
}

extension Account {
    static let byHand = Schema.object(
        Account.self, unknownKeys: .ignore,
        doc: "A wire model: `id` and `name` must be there, `email` may be missing or null, the rest has defaults."
    ) { f in
        let id = f.field("id", \.id, .int(), doc: "The account number.")
        let name = f.field("name", \.name, .string(.length(1...40)), doc: "The display name.")
        let email = f.field("email", \.email, .optional(.string(), nullable: true), doc: "Where to write, if known.")
        let createdAt = f.field("created_at", \.createdAt, .date(), doc: "When it was opened.")
        let credit = f.field("credit", \.credit, .double(.range(0...100)), default: 0, doc: "Prepaid credit.")
        let tags = f.field("tags", \.tags, .array(of: .string()), default: [], doc: "Free-form labels.")
        return f.build { v in
            Account(
                id: v[id], name: v[name], email: v[email], createdAt: v[createdAt], credit: v[credit], tags: v[tags])
        }
    }
}

/// Required fields beside a preserved-keys property.
@Schema
struct Envelope: Equatable {
    /// What it is.
    var kind: String
    @PreserveUnknownKeys var extra: JSONObject = [:]
}

@Suite("@Schema: required fields")
struct RequiredFieldTests {
    @Test func itIsTheSchemaWrittenByHand() {
        expectEquivalent(Account.schema, Account.byHand)
    }

    @Test(.failureMode("design/06", "a required field's key is missing"))
    func aMissingRequiredKeyIsAnIssueNotAZero() {
        let decoded = Account.schema.decode(["name": "Ada", "created_at": "2024-01-01T00:00:00Z"])
        #expect(decoded.value == nil)
        #expect(decoded.issues.map { "\($0.path) \($0.code)" } == ["$.id missing_key"])
    }

    @Test func everyMissingKeyIsReportedAtOnce() {
        let decoded = Account.schema.decode([:])
        #expect(
            decoded.issues.map { "\($0.path) \($0.code)" }.sorted() == [
                "$.created_at missing_key", "$.id missing_key", "$.name missing_key",
            ])
    }

    @Test func optionalsMayBeMissingOrNull() {
        func account(email: JSONValue?) -> JSONValue {
            var object: JSONObject = ["id": 1, "name": "Ada", "created_at": "2024-01-01T00:00:00Z"]
            if let email { object["email"] = email }
            return .object(object)
        }
        #expect(Account.schema.decode(account(email: nil)).value?.email == nil)
        #expect(Account.schema.decode(account(email: .null)).issues.isEmpty)
        #expect(Account.schema.decode(account(email: "ada@example.com")).value?.email == "ada@example.com")
    }

    @Test func fieldsWithDefaultsKeepThem() {
        let decoded = Account.schema.decode(["id": 7, "name": "Ada", "created_at": "2024-01-01T00:00:00Z"])
        #expect(decoded.value?.credit == 0)
        #expect(decoded.value?.tags == [])
        #expect(decoded.value?.cache == [:])
    }

    @Test func otherIssuesAreReportedBesideTheMissingKey() {
        let decoded = Account.schema.decode(["name": "", "credit": 101, "created_at": "yesterday"])
        #expect(
            decoded.issues.map { "\($0.path) \($0.code)" }.sorted() == [
                "$.created_at invalid_format", "$.credit out_of_range", "$.id missing_key", "$.name too_short",
            ])
    }

    @Test func aRequiredFieldIsAlwaysWritten() {
        let account = Account(id: 0, name: "Ada", email: nil, createdAt: Date(timeIntervalSince1970: 0))
        let sparse = Account.schema.encode(account, style: .sparse)
        #expect(sparse.object?["id"] == 0)
        #expect(sparse.object?["credit"] == nil)
        #expect(Account.schema.decode(sparse).value == account)
    }

    @Test func theExportListsTheRequiredKeys() {
        let required = Account.schema.jsonSchema().object?["required"]?.array?.compactMap(\.string)
        #expect(Set(required ?? []) == ["id", "name", "created_at"])
    }

    @Test func preservedKeysAndRequiredFieldsTogether() {
        let decoded = Envelope.schema.decode(["kind": "k", "more": 1])
        #expect(decoded.value == Envelope(kind: "k", extra: ["more": 1]))
        #expect(Envelope.schema.decode(["more": 1]).issues.map(\.code) == [.missingKey])
    }

    @Test func theSuiteIsClean() {
        let report = expectSchemaSuite(Account.schema, seed: 3, cases: 150)
        #expect(report.isClean, "\(report)")
    }
}
#endif
