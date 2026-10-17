import StoicJSON
import StoicTesting
import Testing

/// A path written as its parts: strings are keys, integers are indexes.
private struct Part: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    let component: JSONPath.Component
    init(stringLiteral value: String) { component = .key(value) }
    init(integerLiteral value: Int) { component = .index(value) }
}

private func p(_ parts: Part...) -> JSONPath {
    JSONPath(parts.map(\.component))
}

@Suite("JSONChange")
struct ChangeTests {
    private func json(_ text: String) throws -> JSONValue {
        try #require(parse(text).value)
    }

    private func changes(_ old: String, _ new: String) throws -> [JSONChange] {
        JSONChange.between(try json(old), try json(new))
    }

    // MARK: Finding changes

    @Test func equalValuesHaveNoChanges() throws {
        #expect(try changes(#"{"a": [1, {"b": null}], "c": "x"}"#, #"{"c": "x", "a": [1, {"b": null}]}"#).isEmpty)
        #expect(try changes("3", "3").isEmpty)
        #expect(try changes("{}", "{}").isEmpty)
    }

    @Test func aChangedLeafIsOneChangeAtItsPath() throws {
        let found = try changes(#"{"scroll": {"speed": 600, "smooth": true}, "name": "a"}"#, #"{"scroll": {"speed": 900, "smooth": true}, "name": "a"}"#)
        #expect(found == [JSONChange(path: p("scroll", "speed"), old: 600, new: 900)])
        #expect(found.first?.description == "$.scroll.speed: 600 -> 900")
    }

    @Test func anAddedAndARemovedMemberAreEachOneChangeHoldingTheWholeValue() throws {
        let found = try changes(#"{"gone": {"b": 1, "c": [2]}, "kept": 1}"#, #"{"kept": 1, "new": {"d": {"e": null}}}"#)
        #expect(found == [
            JSONChange(path: p("gone"), old: try json(#"{"b": 1, "c": [2]}"#), new: nil),
            JSONChange(path: p("new"), old: nil, new: try json(#"{"d": {"e": null}}"#)),
        ])
        #expect(found[0].description == #"$.gone: removed {"b":1,"c":[2]}"#)
        #expect(found[1].description == #"$.new: added {"d":{"e":null}}"#)
    }

    @Test func aValueThatChangesKindIsOneChange() throws {
        #expect(try changes(#"{"a": 1}"#, #"{"a": "1"}"#) == [JSONChange(path: p("a"), old: 1, new: "1")])
        let toObject = try changes(#"{"a": 1}"#, #"{"a": {"b": 1}}"#)
        #expect(toObject == [JSONChange(path: p("a"), old: 1, new: try json(#"{"b": 1}"#))])
        let fromObject = try changes(#"{"a": {"b": 1}}"#, #"{"a": null}"#)
        #expect(fromObject == [JSONChange(path: p("a"), old: try json(#"{"b": 1}"#), new: .null)])
    }

    /// A difference in an array is one change holding both arrays: matching
    /// elements would be a guess, and a history that guessed wrong would undo
    /// what the person never did.
    @Test(.failureMode("design/06", "two documents differ inside an array")) func arraysAreLeaves() throws {
        let found = try changes(#"{"hosts": ["a", "b", "c"], "n": 1}"#, #"{"hosts": ["a", "c"], "n": 1}"#)
        #expect(found == [JSONChange(path: p("hosts"), old: try json(#"["a", "b", "c"]"#), new: try json(#"["a", "c"]"#))])
        // Objects inside arrays are not looked into either.
        let inside = try changes(#"{"l": [{"a": 1}]}"#, #"{"l": [{"a": 2}]}"#)
        #expect(inside.map(\.path) == [p("l")])
    }

    @Test func valuesThatAreNotBothObjectsDifferAtTheRoot() throws {
        #expect(try changes("[1]", "[2]") == [JSONChange(path: .root, old: try json("[1]"), new: try json("[2]"))])
        #expect(try changes("1", #"{"a": 1}"#).map(\.path) == [.root])
    }

    @Test func changesDoNotDependOnTheOrderMembersWereWrittenIn() throws {
        let one = try changes(#"{"b": 1, "a": 1, "d": 1}"#, #"{"c": 1, "b": 2, "a": 2}"#)
        let other = try changes(#"{"d": 1, "a": 1, "b": 1}"#, #"{"a": 2, "b": 2, "c": 1}"#)
        #expect(one == other)
        #expect(one.map(\.path) == [p("a"), p("b"), p("c"), p("d")], "in the order of the keys")
    }

    @Test func keysThatDifferOnlyByCanonicalEquivalenceAreTwoKeys() throws {
        let old = JSONValue.object(JSONObject([.init(key: "\u{E9}", value: 1)]))
        let new = JSONValue.object(JSONObject([.init(key: "e\u{301}", value: 1)]))
        #expect(JSONChange.between(old, new).count == 2)
    }

    // MARK: Applying

    @Test func aChangeIsMadeAndItsInverseUnmakesIt() throws {
        let before = try json(#"{"a": {"b": 1}, "c": 2}"#)
        for change in [
            JSONChange(path: p("a", "b"), old: 1, new: 5),
            JSONChange(path: p("a", "x"), old: nil, new: "added"),
            JSONChange(path: p("c"), old: 2, new: nil),
            JSONChange(path: p("a"), old: try json(#"{"b": 1}"#), new: [1, 2]),
        ] {
            let after = try before.applying(change)
            #expect(after != before)
            #expect(after.value(at: change.path) == change.new)
            #expect(try after.applying(change.inverted) == before, "\(change)")
        }
    }

    @Test(.failureMode("design/06", "a change is applied to a value that has moved on")) func aChangeAppliedToAValueThatMovedOnIsAConflict() throws {
        let now = try json(#"{"speed": 700}"#)
        let change = JSONChange(path: p("speed"), old: 600, new: 900)
        #expect(throws: JSONChange.ApplyError.conflict(path: p("speed"), found: 700)) { try now.applying(change) }
        #expect(throws: JSONChange.ApplyError.conflict(path: p("gone"), found: nil)) {
            try now.applying(JSONChange(path: p("gone"), old: 1, new: nil))
        }
        #expect(throws: JSONChange.ApplyError.conflict(path: p("speed"), found: 700)) {
            try now.applying(JSONChange(path: p("speed"), old: nil, new: 1))
        }
        #expect(try now.applying(change, overwriting: true) == (try json(#"{"speed": 900}"#)), "forced, whatever is there")
    }

    @Test func overwritingMakesTheObjectsOnTheWayAndRemovesNothingThatIsNotThere() throws {
        let change = JSONChange(path: p("a", "b", "c"), old: nil, new: 1)
        #expect(throws: JSONChange.ApplyError.blocked(path: p("a"))) { try JSONValue.object([:]).applying(change) }
        #expect(try JSONValue.object([:]).applying(change, overwriting: true) == (try json(#"{"a": {"b": {"c": 1}}}"#)))
        let removal = JSONChange(path: p("a", "b"), old: 1, new: nil)
        #expect(try JSONValue.object([:]).applying(removal, overwriting: true) == .object([:]), "no empty `a` is left behind")
    }

    @Test(.failureMode("design/06", "a change's path leads through the wrong kind of value")) func aPathThroughTheWrongKindOfValueIsBlocked() throws {
        let value = try json(#"{"a": 1, "l": [10, 20]}"#)
        #expect(throws: JSONChange.ApplyError.blocked(path: p("a", "b"))) {
            try value.applying(JSONChange(path: p("a", "b"), old: nil, new: 1), overwriting: true)
        }
        #expect(throws: JSONChange.ApplyError.blocked(path: p("l", "x"))) {
            try value.applying(JSONChange(path: p("l", "x"), old: nil, new: 1))
        }
        #expect(throws: JSONChange.ApplyError.blocked(path: p("a", 0))) {
            try value.applying(JSONChange(path: p("a", 0), old: 1, new: 2))
        }
        #expect(throws: JSONChange.ApplyError.blocked(path: p("l", 5))) {
            try value.applying(JSONChange(path: p("l", 5, "k"), old: nil, new: 1))
        }
    }

    @Test(.failureMode("design/06", "a change adds or removes an element of an array")) func anArrayElementCanBeReplacedButNotAddedOrRemoved() throws {
        let value = try json(#"{"l": [10, {"k": 1}]}"#)
        #expect(try value.applying(JSONChange(path: p("l", 0), old: 10, new: 11)) == (try json(#"{"l": [11, {"k": 1}]}"#)))
        #expect(try value.applying(JSONChange(path: p("l", 1, "k"), old: 1, new: 2)) == (try json(#"{"l": [10, {"k": 2}]}"#)))
        #expect(throws: JSONChange.ApplyError.arrayElement(path: p("l", 2))) {
            try value.applying(JSONChange(path: p("l", 2), old: nil, new: 1))
        }
        #expect(throws: JSONChange.ApplyError.arrayElement(path: p("l", 0))) {
            try value.applying(JSONChange(path: p("l", 0), old: 10, new: nil))
        }
    }

    @Test func theRootIsReplacedButNeverRemoved() throws {
        #expect(try json("[1]").applying(JSONChange(path: .root, old: try json("[1]"), new: 2)) == 2)
        #expect(throws: JSONChange.ApplyError.removesRoot) { try json("[1]").applying(JSONChange(path: .root, old: try json("[1]"), new: nil)) }
    }

    @Test func aListOfChangesAppliesInOrderAndAFailureAppliesNone() throws {
        let before = try json(#"{"a": 1, "b": 2}"#)
        let list = [JSONChange(path: p("a"), old: 1, new: 5), JSONChange(path: p("b"), old: 3, new: 9)]
        #expect(throws: JSONChange.ApplyError.conflict(path: p("b"), found: 2)) { try before.applyingAll(list) }
        let fine = [JSONChange(path: p("a"), old: 1, new: 5), JSONChange(path: p("a"), old: 5, new: 6)]
        #expect(try before.applyingAll(fine) == (try json(#"{"a": 6, "b": 2}"#)))
    }

    // MARK: Properties

    /// A value like `value` with some of it changed, added or removed, so a
    /// pair shares structure the way an edited document does.
    private func edited(_ value: JSONValue, _ generator: inout JSONGenerator) -> JSONValue {
        guard case .object(let object) = value, generator.chance(85) else {
            return generator.chance(50) ? value : generator.value(depth: 3)
        }
        var result = JSONObject()
        for member in object where !generator.chance(15) {
            result[member.key] = edited(member.value, &generator)
        }
        if generator.chance(40) { result[generator.string()] = generator.value(depth: 2) }
        return .object(result)
    }

    @Test("applying the changes between two values to the first gives the second", arguments: Array(1...400) as [UInt64])
    func applyingTheDiffGivesTheOtherValue(_ seed: UInt64) throws {
        var generator = JSONGenerator(seed: seed)
        // An object at the root, so there is structure for the pair to share.
        var root = JSONObject()
        for _ in 0..<generator.int(1...6) { root[generator.string()] = generator.value(depth: 1) }
        let old = JSONValue.object(root)
        for new in [edited(old, &generator), generator.value()] {
            let found = JSONChange.between(old, new)
            #expect(found.isEmpty == (old == new), "seed \(seed)")
            #expect(try old.applyingAll(found) == new, "seed \(seed)")
            // And back: the inverses, last first, restore the old value.
            #expect(try new.applyingAll(found.reversed().map(\.inverted)) == old, "seed \(seed)")
            // Each change is a real difference at the deepest place.
            for change in found { #expect(change.old != change.new, "seed \(seed): \(change)") }
        }
    }
}
