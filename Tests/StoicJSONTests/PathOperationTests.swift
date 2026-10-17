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

private func json(_ text: String) throws -> JSONValue {
    try #require(parse(text).value)
}

/// Reading and writing a value at a path, and reading a dotted address into one.
@Suite("JSON paths: set, remove and dotted addresses")
struct PathOperationTests {
    // MARK: Setting

    @Test(.failureMode("design/06", "a value is set at a path whose objects are not there"))
    func settingMakesTheObjectsOnTheWay() throws {
        let result = try JSONValue.object([:]).setting("x", at: p("web", "routes", "github.com"))
        #expect(result == (try json(#"{"web": {"routes": {"github.com": "x"}}}"#)))
        #expect(result.value(at: p("web", "routes", "github.com")) == "x")
    }

    @Test func aMemberThatExistsKeepsItsPlaceAndANewOneIsAppended() throws {
        let start = try json(#"{"b": 1, "a": 2, "c": 3}"#)
        #expect(try start.setting(9, at: p("a")).encodedString(style: .compact) == #"{"b":1,"a":9,"c":3}"#)
        #expect(try start.setting(9, at: p("d")).encodedString(style: .compact) == #"{"b":1,"a":2,"c":3,"d":9}"#)
    }

    @Test func settingTheRootGivesTheValueAndAnElementThatExistsCanBeReplaced() throws {
        #expect(try JSONValue.null.setting(3, at: .root) == 3)
        let start = try json(#"{"hosts": [{"n": 1}, {"n": 2}]}"#)
        #expect(try start.setting(7, at: p("hosts", 1, "n")) == (try json(#"{"hosts": [{"n": 1}, {"n": 7}]}"#)))
        #expect(try start.setting("x", at: p("hosts", 0)) == (try json(#"{"hosts": ["x", {"n": 2}]}"#)))
    }

    @Test(.failureMode("design/06", "a value is set where a value that is not an object is in the way"))
    func settingThroughAValueThatIsNotAnObjectIsBlockedAtThatValue() throws {
        let start = try json(#"{"scroll": 3, "gone": null, "list": [1]}"#)
        for (path, blocker, found) in [
            (p("scroll", "speed"), p("scroll"), JSONValue(3)),
            (p("gone", "x"), p("gone"), JSONValue.null),
            (p("scroll", "a", "b"), p("scroll"), JSONValue(3)),
            (p("list", "k"), p("list"), JSONValue.array([1])),
        ] {
            let error = #expect(throws: JSONPathError.self) { try start.setting(1, at: path) }
            #expect(error == .blocked(path: blocker, found: found), "\(path)")
        }
        // An index into an object is blocked as well.
        let error = #expect(throws: JSONPathError.self) { try start.setting(1, at: p(0)) }
        #expect(error == .blocked(path: .root, found: start))
    }

    @Test(.failureMode("design/06", "a value is set at an index past the end of an array"))
    func anIndexPastTheEndIsAnArrayElementFailure() throws {
        let start = try json(#"{"hosts": ["a"]}"#)
        let error = #expect(throws: JSONPathError.self) { try start.setting("b", at: p("hosts", 1)) }
        #expect(error == .arrayElement(path: p("hosts", 1)))
        let deeper = #expect(throws: JSONPathError.self) { try start.setting("b", at: p("hosts", 4, "n")) }
        #expect(deeper == .arrayElement(path: p("hosts", 4)))
    }

    // MARK: Removing

    @Test func removingTakesOutTheMemberAndNothingElse() throws {
        let start = try json(#"{"a": {"b": 1, "c": 2}, "d": 3}"#)
        #expect(try start.removing(at: p("a", "b")) == (try json(#"{"a": {"c": 2}, "d": 3}"#)))
        #expect(try start.removing(at: p("a")) == (try json(#"{"d": 3}"#)))
    }

    @Test(.failureMode("design/06", "a value is removed that is not there"))
    func removingWhatIsNotThereChangesNothing() throws {
        let start = try json(#"{"a": {"b": 1}, "s": "text", "list": [1]}"#)
        for path in [p("x"), p("a", "z"), p("x", "y", "z"), p("s", "k"), p("list", 4), p("list", 4, "k"), p("a", 0)] {
            #expect(try start.removing(at: path) == start, "\(path)")
            #expect(try start.removing(at: path, pruning: true) == start, "\(path), pruning")
        }
    }

    @Test(.failureMode("design/06", "the last member of an object is removed with `pruning`"))
    func pruningRemovesTheObjectsTheRemovalLeftEmpty() throws {
        let start = try json(#"{"web": {"routes": {"a.com": 1}}, "other": {}, "keep": {"x": 1}}"#)
        #expect(try start.removing(at: p("web", "routes", "a.com"), pruning: true) == (try json(#"{"other": {}, "keep": {"x": 1}}"#)))
        #expect(try start.removing(at: p("web", "routes", "a.com")) == (try json(#"{"web": {"routes": {}}, "other": {}, "keep": {"x": 1}}"#)))
        // Pruning stops at the first object that still holds something, and never takes an object that was already empty.
        let two = try json(#"{"web": {"routes": {"a.com": 1}, "links": 2}, "other": {}}"#)
        #expect(try two.removing(at: p("web", "routes", "a.com"), pruning: true) == (try json(#"{"web": {"links": 2}, "other": {}}"#)))
        #expect(try JSONValue.object(["a": .object([:])]).removing(at: p("a"), pruning: true) == .object([:]))
    }

    @Test func pruningNeverRemovesTheRootOrAnElementOfAnArray() throws {
        let only = try json(#"{"a": {"b": 1}}"#)
        #expect(try only.removing(at: p("a", "b"), pruning: true) == .object([:]))
        let inArray = try json(#"{"list": [{"a": {"b": 1}}, {"c": 2}]}"#)
        #expect(try inArray.removing(at: p("list", 0, "a", "b"), pruning: true) == (try json(#"{"list": [{}, {"c": 2}]}"#)))
    }

    @Test(.failureMode("design/06", "an element of an array is removed"))
    func anElementOfAnArrayCannotBeRemovedAndTheRootCannotEither() throws {
        let start = try json(#"{"hosts": ["a", "b"]}"#)
        let element = #expect(throws: JSONPathError.self) { try start.removing(at: p("hosts", 0)) }
        #expect(element == .arrayElement(path: p("hosts", 0)))
        let root = #expect(throws: JSONPathError.self) { try start.removing(at: .root) }
        #expect(root == .root)
        // What is not there is not an element: removing it is the no-op it is anywhere else.
        #expect(try start.removing(at: p("hosts", 5)) == start)
    }

    @Test func setThenRemoveIsTheStartWhenPruning() throws {
        let start = try json(#"{"a": 1}"#)
        let path = p("web", "routes", "github.com")
        #expect(try start.setting(true, at: path).removing(at: path, pruning: true) == start)
    }

    @Test func descriptionsSayWhereAndWhy() {
        #expect(JSONPathError.blocked(path: p("scroll"), found: 3).description.contains("$.scroll: it is number"))
        #expect(JSONPathError.arrayElement(path: p("a", 1)).description.contains("$.a[1]"))
        #expect(JSONPathError.root.description.contains("whole document"))
    }

    // MARK: Dotted addresses

    /// What an app with a table of routes keyed by hostname, a table of links
    /// whose values are objects, and ordinary sections declares.
    static let shape: JSONPath.Shape = .fields([
        "scroll": .fields(["speed": .value, "smooth": .value]),
        "web": .fields([
            "routes": .freeKeys(.value),
            "links": .freeKeys(.fields(["url": .value, "title": .value])),
            "hosts": .elements(.fields(["name": .value])),
        ]),
        "extra": .value,
    ])

    @Test(.failureMode("design/06", "a dotted address has a free key with dots in it"))
    func aFreeKeyKeepsItsDots() throws {
        #expect(JSONPath(address: "web.routes.github.com", shape: Self.shape) == p("web", "routes", "github.com"))
        #expect(JSONPath(address: "web.routes.a.b.c.d", shape: Self.shape) == p("web", "routes", "a.b.c.d"))
        // The key is the fewest segments that leave a remainder the shape reads.
        #expect(JSONPath(address: "web.links.my.site.url", shape: Self.shape) == p("web", "links", "my.site", "url"))
        #expect(JSONPath(address: "web.links.github.com", shape: Self.shape) == p("web", "links", "github.com"))
        #expect(JSONPath(address: "web.links.title.title", shape: Self.shape) == p("web", "links", "title", "title"))
        #expect(JSONPath(address: "scroll.speed", shape: Self.shape) == p("scroll", "speed"))
        #expect(JSONPath(address: "web.routes", shape: Self.shape) == p("web", "routes"))
    }

    @Test func theAddressesOfAPathAreSetAndRemovedLikeAnyPath() throws {
        let path = try #require(JSONPath(address: "web.routes.github.com", shape: Self.shape))
        let document = try JSONValue.object([:]).setting("brave", at: path)
        #expect(document == (try json(#"{"web": {"routes": {"github.com": "brave"}}}"#)))
        #expect(try document.removing(at: path, pruning: true) == .object([:]))
    }

    @Test(.failureMode("design/06", "a dotted address names what the shape does not describe"))
    func anAddressTheShapeDoesNotDescribeIsReadAsPlainKeys() {
        #expect(JSONPath(address: "nosuch.a.b", shape: Self.shape) == p("nosuch", "a", "b"))
        #expect(JSONPath(address: "scroll.speed.fast.x", shape: Self.shape) == p("scroll", "speed", "fast", "x"))
        #expect(JSONPath(address: "web.zzz.k", shape: Self.shape) == p("web", "zzz", "k"))
        #expect(JSONPath(address: "extra.any.thing", shape: Self.shape) == p("extra", "any", "thing"))
        #expect(JSONPath(address: "a.b", shape: .value) == p("a", "b"))
    }

    @Test func arrayElementsAreAddressedByDigits() {
        #expect(JSONPath(address: "web.hosts.1.name", shape: Self.shape) == p("web", "hosts", 1, "name"))
        #expect(JSONPath(address: "web.hosts.first.name", shape: Self.shape) == p("web", "hosts", "first", "name"))
        #expect(JSONPath(address: "web.hosts.01", shape: Self.shape) == p("web", "hosts", "01"), "a leading zero is not an index")
    }

    @Test(.failureMode("design/06", "a dotted address has an empty segment"))
    func anEmptySegmentIsNoAddressAndTheEmptyAddressIsTheRoot() {
        for address in [".a", "a.", "a..b", "."] {
            #expect(JSONPath(address: address, shape: Self.shape) == nil, "\(address)")
        }
        #expect(JSONPath(address: "", shape: Self.shape) == .root)
    }

    @Test func aShapeThatContainsItselfIsReadAsFarAsTheAddressGoes() {
        // A tree: each node has a `children` table keyed by name, whose values are nodes.
        @Sendable func node() -> JSONPath.Shape {
            .fields(["children": .freeKeys(.deferred(node)), "label": .value])
        }
        #expect(
            JSONPath(address: "children.a.b.children.c.label", shape: node())
                == p("children", "a.b", "children", "c", "label"))
        #expect(JSONPath(address: "children.x.label", shape: node()) == p("children", "x", "label"))
    }
}
