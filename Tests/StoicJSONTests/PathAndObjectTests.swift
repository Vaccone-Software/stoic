import StoicJSON
import Testing

@Suite("JSONPath")
struct PathTests {
    @Test func rendersDotAndIndexNotation() {
        #expect(JSONPath.root.description == "$")
        #expect(JSONPath([.key("a"), .key("b"), .index(3)]).description == "$.a.b[3]")
        #expect(JSONPath([.index(0), .index(1)]).description == "$[0][1]")
        #expect(JSONPath([.key("network"), .key("hosts"), .index(3), .key("port")]).description == "$.network.hosts[3].port")
    }

    @Test func quotesKeysThatAreNotIdentifiers() {
        #expect(JSONPath([.key("a b")]).description == #"$["a b"]"#)
        #expect(JSONPath([.key("")]).description == #"$[""]"#)
        #expect(JSONPath([.key("1abc")]).description == #"$["1abc"]"#)
        #expect(JSONPath([.key("a-b")]).description == #"$["a-b"]"#)
        #expect(JSONPath([.key("a.b")]).description == #"$["a.b"]"#)
        #expect(JSONPath([.key("caf\u{E9}")]).description == "$[\"caf\u{E9}\"]")
        #expect(JSONPath([.key("say \"hi\"")]).description == #"$["say \"hi\""]"#)
        #expect(JSONPath([.key("back\\slash")]).description == #"$["back\\slash"]"#)
        #expect(JSONPath([.key("line\nbreak")]).description == #"$["line\nbreak"]"#)
        #expect(JSONPath([.key("a"), .key("b c"), .index(2), .key("d")]).description == #"$.a["b c"][2].d"#)
    }

    @Test func identifiersMayUseUnderscoreDollarAndDigits() {
        #expect(JSONPath([.key("_private")]).description == "$._private")
        #expect(JSONPath([.key("$ref")]).description == "$.$ref")
        #expect(JSONPath([.key("a1_b2")]).description == "$.a1_b2")
    }

    @Test func rendersJSONPointerWithEscapes() {
        #expect(JSONPath.root.pointer == "")
        #expect(JSONPath([.key("a"), .key("b"), .index(3)]).pointer == "/a/b/3")
        #expect(JSONPath([.key("a/b")]).pointer == "/a~1b")
        #expect(JSONPath([.key("m~n")]).pointer == "/m~0n")
        #expect(JSONPath([.key("~/")]).pointer == "/~0~1")
        #expect(JSONPath([.key("~1")]).pointer == "/~01")
        #expect(JSONPath([.key("")]).pointer == "/")
        #expect(JSONPath([.key("a b"), .key("\u{E9}")]).pointer == "/a b/\u{E9}")
    }

    @Test func rfc6901Samples() throws {
        // RFC 6901 section 5.
        let document = try #require(parse(#"""
            {"foo":["bar","baz"],"":0,"a/b":1,"c%d":2,"e^f":3,"g|h":4,"i\\j":5,"k\"l":6," ":7,"m~n":8}
            """#).value)
        let expectations: [(String, JSONValue?)] = [
            ("/foo/0", "bar"), ("/foo/1", "baz"), ("/", 0), ("/a~1b", 1), ("/c%d", 2),
            ("/e^f", 3), ("/g|h", 4), ("/i\\j", 5), ("/k\"l", 6), ("/ ", 7), ("/m~0n", 8),
        ]
        for (pointer, expected) in expectations {
            let path = try #require(JSONPath(pointer: pointer, resolvingAgainst: document), "\(pointer)")
            #expect(document.value(at: path) == expected, "\(pointer)")
            #expect(path.pointer == pointer)
        }
        #expect(JSONPath(pointer: "")?.isEmpty == true)
    }

    @Test func parsesPointers() {
        #expect(JSONPath(pointer: "/a/b/3") == [.key("a"), .key("b"), .index(3)])
        #expect(JSONPath(pointer: "/a~1b/m~0n") == [.key("a/b"), .key("m~n")])
        #expect(JSONPath(pointer: "/~01") == [.key("~1")])
        #expect(JSONPath(pointer: "/") == [.key("")])
        #expect(JSONPath(pointer: "//") == [.key(""), .key("")])
        #expect(JSONPath(pointer: "/0") == [.index(0)])
    }

    @Test func tokensThatBeginWithACombiningMarkStayApart() {
        // `/` and U+0301 are one Character; splitting on Characters would
        // fuse the second token into the first, and drop the mark from the
        // first token of all.
        #expect(JSONPath(pointer: "/a/\u{301}b") == [.key("a"), .key("\u{301}b")])
        #expect(JSONPath(pointer: "/\u{301}") == [.key("\u{301}")])
        let path: JSONPath = [.key("x"), .key("\u{301}~/")]
        #expect(JSONPath(pointer: path.pointer) == path)
    }

    @Test(arguments: ["a", "a/b", "/a~", "/a~2", "/~", "/a~b", "~0"])
    func rejectsMalformedPointers(_ pointer: String) {
        #expect(JSONPath(pointer: pointer) == nil)
    }

    @Test func digitTokensWithoutContextFollowTheArrayIndexGrammar() {
        #expect(JSONPath(pointer: "/01") == [.key("01")])
        #expect(JSONPath(pointer: "/-") == [.key("-")])
        #expect(JSONPath(pointer: "/+1") == [.key("+1")])
        #expect(JSONPath(pointer: "/99999999999999999999") == [.key("99999999999999999999")])
        #expect(JSONPath(pointer: "/1.5") == [.key("1.5")])
    }

    @Test func resolvingAgainstTheDocumentDisambiguatesNumericKeys() throws {
        let document = try #require(parse(#"{"a":{"3":"key"},"b":["x","y","z","index"]}"#).value)
        let key = try #require(JSONPath(pointer: "/a/3", resolvingAgainst: document))
        #expect(key == [.key("a"), .key("3")])
        #expect(document.value(at: key) == "key")
        let index = try #require(JSONPath(pointer: "/b/3", resolvingAgainst: document))
        #expect(index == [.key("b"), .index(3)])
        #expect(document.value(at: index) == "index")
        // Where the path leaves the document, the digit rule applies.
        #expect(JSONPath(pointer: "/missing/3", resolvingAgainst: document) == [.key("missing"), .index(3)])
    }

    @Test func pointerRoundTripsThroughDescriptionOfTheSameKeys() {
        let paths: [JSONPath] = [
            [], [.key("a")], [.key("a"), .index(0)], [.key("a/b"), .key("~"), .index(12)],
            [.key(""), .key(" "), .key("\u{1F600}")], [.index(5), .index(0)],
        ]
        for path in paths {
            #expect(JSONPath(pointer: path.pointer) == path, "\(path)")
        }
    }

    @Test func pointerRoundTripWithNumericKeysNeedsTheDocument() throws {
        let document = try #require(parse(#"{"3":{"4":[0,1]}}"#).value)
        let path: JSONPath = [.key("3"), .key("4"), .index(1)]
        #expect(JSONPath(pointer: path.pointer) != path)  // ambiguous on its own
        #expect(JSONPath(pointer: path.pointer, resolvingAgainst: document) == path)
    }

    @Test func pathsCompareKeysByScalars() {
        #expect(JSONPath([.key("\u{E9}")]) != JSONPath([.key("e\u{301}")]))
        #expect(JSONPath([.key("\u{E9}")]) == JSONPath([.key("\u{E9}")]))
        #expect(Set([JSONPath([.key("\u{E9}")]), JSONPath([.key("e\u{301}")])]).count == 2)
        #expect(JSONPath([.index(1)]) != JSONPath([.key("1")]))
    }

    @Test func buildingAndNavigatingPaths() {
        let path = JSONPath.root.appending(key: "a").appending(index: 2)
        #expect(path == [.key("a"), .index(2)])
        #expect(path.parent == [.key("a")])
        #expect(path.parent?.parent == .root)
        #expect(JSONPath.root.parent == nil)
        #expect(path.count == 2)
        #expect(path.last == .index(2))
    }

    @Test func valueLookupFollowsPaths() throws {
        let value = try #require(parse(#"{"a":[10,{"b":"x"}]}"#).value)
        #expect(value.value(at: .root) == value)
        #expect(value.value(at: [.key("a"), .index(0)]) == 10)
        #expect(value.value(at: [.key("a"), .index(1), .key("b")]) == "x")
        #expect(value.value(at: [.key("a"), .index(2)]) == nil)
        #expect(value.value(at: [.key("a"), .index(-1)]) == nil)
        #expect(value.value(at: [.key("z")]) == nil)
        #expect(value.value(at: [.index(0)]) == nil)
        #expect(value.value(at: [.key("a"), .key("b")]) == nil)
    }
}

@Suite("JSONObject")
struct ObjectTests {
    @Test func preservesSourceOrder() throws {
        let object = try #require(parse(#"{"z":1,"a":2,"m":3,"b":4}"#).value?.object)
        #expect(object.keyList == ["z", "a", "m", "b"])
        #expect(object.map(\.value) == [1, 2, 3, 4])
        #expect(object[0].key == "z")
        #expect(object.index(forKey: "m") == 2)
    }

    @Test func lookupByKey() throws {
        let object: JSONObject = ["a": 1, "b": "two"]
        #expect(object["a"] == 1)
        #expect(object["b"] == "two")
        #expect(object["c"] == nil)
        #expect(object.contains(key: "a"))
        #expect(!object.contains(key: "c"))
        #expect(object.index(forKey: "c") == nil)
    }

    @Test func equalityIgnoresMemberOrder() throws {
        let a = try #require(parse(#"{"a":1,"b":[1,2],"c":{"x":null}}"#).value)
        let b = try #require(parse(#"{"c":{"x":null},"b":[1,2],"a":1}"#).value)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
        #expect(a != (try #require(parse(#"{"a":1,"b":[2,1],"c":{"x":null}}"#).value)))
        #expect(a != (try #require(parse(#"{"a":1,"b":[1,2]}"#).value)))
        #expect(a != (try #require(parse(#"{"a":1,"b":[1,2],"d":{"x":null}}"#).value)))
    }

    @Test func arrayOrderMatters() {
        #expect(JSONValue.array([1, 2]) != JSONValue.array([2, 1]))
    }

    @Test func mutationReplacesInPlaceAppendsAndRemoves() {
        var object: JSONObject = ["a": 1, "b": 2, "c": 3]
        object["b"] = 20
        #expect(object.keyList == ["a", "b", "c"])
        #expect(object["b"] == 20)
        object["d"] = 4
        #expect(object.keyList == ["a", "b", "c", "d"])
        object["a"] = nil
        #expect(object.keyList == ["b", "c", "d"])
        #expect(object.index(forKey: "b") == 0)
        #expect(object.index(forKey: "d") == 2)
        #expect(object["a"] == nil)
        object["zzz"] = nil  // absent: no-op
        #expect(object.count == 3)
        object["a"] = 5
        #expect(object.keyList == ["b", "c", "d", "a"])
        #expect(object["c"] == 3)
    }

    @Test func removingEveryMemberLeavesAnEmptyObject() {
        var object: JSONObject = ["a": 1, "b": 2]
        object["a"] = nil
        object["b"] = nil
        #expect(object.isEmpty)
        #expect(object == JSONObject())
        #expect(object["a"] == nil)
    }

    @Test func initialiserFromMembersLetsLaterDuplicatesReplace() {
        let object = JSONObject([
            JSONObject.Member(key: "a", value: 1),
            JSONObject.Member(key: "b", value: 2),
            JSONObject.Member(key: "a", value: 3),
        ])
        #expect(object.keyList == ["a", "b"])
        #expect(object["a"] == 3)
    }

    @Test func keysAreExactScalars() {
        var object = JSONObject()
        object["\u{E9}"] = 1
        object["e\u{301}"] = 2
        #expect(object.count == 2)
        #expect(object["\u{E9}"] == 1)
        #expect(object["e\u{301}"] == 2)
        let precomposed: JSONObject = ["\u{E9}": 1]
        let decomposed: JSONObject = ["e\u{301}": 1]
        #expect(precomposed != decomposed)
    }

    @Test func equalityAgreesWithHashing() {
        let a: JSONObject = ["k": [1, 2, "x"], "j": nil]
        let b: JSONObject = ["j": nil, "k": [1, 2, "x"]]
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func collectionConformance() {
        let object: JSONObject = ["a": 1, "b": 2]
        #expect(object.count == 2)
        #expect(object.startIndex == 0 && object.endIndex == 2)
        #expect(Array(object.reversed().map(\.key)) == ["b", "a"])
    }

    @Test func accessorsAndKindNames() {
        #expect(JSONValue.null.isNull)
        #expect(JSONValue.bool(true).bool == true)
        #expect(JSONValue.string("s").string == "s")
        #expect(JSONValue.number(JSONNumber(1)).number?.int64 == 1)
        #expect(JSONValue.array([]).array?.isEmpty == true)
        #expect(JSONValue.object(JSONObject()).object?.isEmpty == true)
        #expect(JSONValue.null.bool == nil)
        let names = [JSONValue.null, true, 1, "s", [], [:]].map(\.kindName)
        #expect(names == ["null", "boolean", "number", "string", "array", "object"])
    }

    @Test func literalsBuildValues() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": [:]]
        #expect(value.value(at: [.key("a"), .index(1)]) == JSONValue.number(try #require(JSONNumber(2.5))))
        #expect(value.value(at: [.key("a"), .index(4)]) == .null)
    }
}
