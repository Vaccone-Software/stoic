#if STOIC_MACROS
import Foundation
import StoicJSON
import StoicMacros
import StoicSchema
import Testing

/// A payload some SDK already decodes.
struct Payload: Codable, Sendable, Equatable {
    var kind: String
    var weight: Double
}

@Schema
struct Envelope2: Equatable {
    /// Who sent it.
    var sender: String
    /// The payload.
    @Codable var payload: Payload
    /// More payloads.
    @Codable var extras: [Payload] = []
    /// A maybe.
    @Codable var note: Payload? = nil
}

/// The same payload, with examples for the suite.
@Schema
struct Parcel: Equatable {
    /// Who sent it.
    var sender: String
    /// The payload.
    @Codable(examples: [Payload(kind: "a", weight: 1), Payload(kind: "b", weight: 2.5)]) var payload: Payload
    /// More payloads.
    @Codable(examples: [Payload(kind: "c", weight: 3)]) var extras: [Payload] = []
}

extension Envelope2 {
    static let byHand = Schema.object(
        Envelope2.self
    ) { f in
        let sender = f.field("sender", \.sender, .string(), doc: "Who sent it.")
        let payload = f.field("payload", \.payload, .codable(Payload.self), doc: "The payload.")
        let extras = f.field("extras", \.extras, .array(of: .codable(Payload.self)), default: [], doc: "More payloads.")
        let note = f.field("note", \.note, .optional(.codable(Payload.self)), default: nil, doc: "A maybe.")
        return f.build { v in Envelope2(sender: v[sender], payload: v[payload], extras: v[extras], note: v[note]) }
    }
}

@Suite("@Schema: Codable leaves")
struct CodableUsageTests {
    @Test func itIsTheSchemaWrittenByHand() {
        #expect(String(describing: Envelope2.schema.node) == String(describing: Envelope2.byHand.node))
        #expect(Envelope2.schema.jsonSchema() == Envelope2.byHand.jsonSchema())
    }

    @Test func theSameDocumentsGiveTheSameAnswers() {
        let documents: [JSONValue] = [
            ["sender": "a", "payload": ["kind": "k", "weight": 1.5]],
            ["sender": "a", "payload": ["kind": "k"], "extras": [["kind": 1], ["kind": "z", "weight": 2]]],
            ["sender": "a", "payload": ["kind": "k", "weight": 1], "note": ["kind": "n", "weight": 3]],
            [:],
        ]
        for document in documents {
            let macro = Envelope2.schema.decode(document)
            let hand = Envelope2.byHand.decode(document)
            #expect(macro.value == hand.value)
            #expect(macro.issues == hand.issues)
        }
    }

    @Test func aFailureIsOneIssueAtTheProperty() {
        let decoded = Envelope2.schema.decode(["sender": "a", "payload": ["kind": "k"], "extras": [["kind": 1]]])
        #expect(decoded.issues.map { "\($0.path) \($0.code)" } == ["$.payload invalid_value", "$.extras[0] invalid_value"])
    }

    @Test func valuesRoundTrip() {
        let value = Envelope2(
            sender: "s", payload: Payload(kind: "k", weight: 1), extras: [Payload(kind: "e", weight: 2)],
            note: Payload(kind: "n", weight: 3))
        #expect(Envelope2.schema.decode(Envelope2.schema.encode(value)).value == value)
    }

    @Test func theExamplesAreWhatTheSuiteGeneratesFrom() {
        let report = SchemaSuite(Parcel.schema).report(seed: 5, cases: 60)
        #expect(report.isClean, "\(report)")
        #expect(report.skipped == 0)
        let hand = Schema.codable(Payload.self, examples: [Payload(kind: "a", weight: 1)])
        #expect(String(describing: hand.node) != String(describing: Schema.codable(Payload.self).node))
    }

    @Test func withoutExamplesTheSuiteSaysSo() {
        let report = SchemaSuite(Envelope2.schema).report(seed: 5, cases: 20)
        #expect(!report.isClean)
        #expect(report.findings.contains { $0.message.contains("$.payload (Payload) is a Codable leaf with no examples") })
    }
}
#endif
