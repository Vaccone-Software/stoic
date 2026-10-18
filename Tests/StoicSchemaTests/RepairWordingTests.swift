import StoicJSON
import StoicTesting
import Testing

@testable import StoicSchema

struct Chooser: Sendable, Equatable {
    var mode = "fast"
    var token = "abc"
    var tags = ["a", "b", "c", "d", "e"]
    var limits = ["a": 1, "b": 2]

    static let schema = Schema.object(Chooser.self, default: Chooser()) {
        Field("mode", \.mode, .string(.oneOf(["fast", "slow", "balanced"])), doc: "The mode.")
        Field("token", \.token, .string(.oneOf(["abc", "abd"])), doc: "A token.", secret: true)
        Field("tags", \.tags, .array(of: .string(), count: 1...5), doc: "Tags.")
        Field("limits", \.limits, .dictionary(of: .int(.range(0...9))), doc: "Limits.")
    }
}

@Suite("Wording of repairs and suggestions")
struct RepairWordingTests {
    @Test(.failureMode("design/06", "a field with a list or an object as its default is repaired"))
    func aCompositeDefaultIsNotRenderedInTheRepair() {
        let decoded = Chooser.schema.decode(["tags": "x", "limits": ["a": 99]], options: .lenient)
        let messages = decoded.repairs.map(\.message)
        #expect(messages.count == 2)
        for message in messages {
            #expect(message.hasSuffix("; used the default"), "\(message)")
        }
        #expect(decoded.repairs.allSatisfy { !$0.description.contains("an object with") && !$0.description.contains("an array of") })
    }

    @Test func aScalarDefaultIsStillSaid() {
        let decoded = Chooser.schema.decode(["mode": "zzzz"], options: .lenient)
        #expect(decoded.repairs.first?.message.hasSuffix("; used the default \"fast\"") == true)
    }

    @Test(.failureMode("design/06", "a string is not one of a closed list"))
    func oneOfSuggestsTheNearestSpellingsAsAnEnumerationDoes() {
        let decoded = Chooser.schema.decode(["mode": "fats"])
        let issue = decoded.errors.first
        #expect(issue?.code == .notOneOf)
        #expect(issue?.suggestions == ["fast"])
        #expect(issue?.description.hasSuffix("(did you mean `fast`?)") == true)
        #expect(Chooser.schema.decode(["mode": "Slow"]).errors.first?.suggestion == "slow")
        // Far from every value: no guess.
        #expect(Chooser.schema.decode(["mode": "xxxxxxxx"]).errors.first?.suggestions == [])
    }

    @Test func theConstraintAloneSuggestsToo() {
        let issue = Constraint.oneOf(["red", "green"]).check("gren").first
        #expect(issue?.suggestions == ["green"])
        #expect(Constraint.oneOf([1, 2]).check("1").first?.suggestions == [])
    }

    @Test func aSecretIsNotSuggestedFromItsSpelling() {
        let decoded = Chooser.schema.decode(["token": "abe"])
        #expect(decoded.errors.first?.suggestions == [])
        #expect(decoded.errors.first?.actual == nil)
    }
}
