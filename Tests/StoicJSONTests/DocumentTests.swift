import StoicJSON
import Testing

@Suite("JSONDocument")
struct DocumentTests {
    private let nested = """
        {
          "name": "caf\u{E9}",
          "hosts": [
            {"host": "a", "port": 80},
            {"host": "b\u{1F600}", "port": 8080}
          ],
          "tls": null
        }
        """

    @Test func rootRangeCoversTheWholeValue() throws {
        let document = try #require(parseDocument("  [1, 2]  "))
        #expect(document.range.start.offset == 2)
        #expect(document.range.end.offset == 8)
        #expect(document.text(in: document.range) == "[1, 2]")
        #expect(document.range(of: .root) == document.range)
    }

    @Test func valueRangesInNestedStructures() throws {
        let document = try #require(parseDocument(nested))
        func text(_ path: JSONPath) -> String? {
            document.range(of: path).flatMap { document.text(in: $0) }
        }
        #expect(text([.key("name")]) == "\"caf\u{E9}\"")
        #expect(text([.key("hosts"), .index(0)]) == #"{"host": "a", "port": 80}"#)
        #expect(text([.key("hosts"), .index(0), .key("port")]) == "80")
        #expect(text([.key("hosts"), .index(1), .key("host")]) == "\"b\u{1F600}\"")
        #expect(text([.key("hosts"), .index(1), .key("port")]) == "8080")
        #expect(text([.key("tls")]) == "null")
        #expect(text([.key("hosts")])?.hasPrefix("[") == true)
        #expect(text([.key("hosts")])?.hasSuffix("]") == true)
    }

    @Test func keyRangesPointAtTheKeyText() throws {
        let document = try #require(parseDocument(nested))
        func keyText(_ path: JSONPath) -> String? {
            document.keyRange(of: path).flatMap { document.text(in: $0) }
        }
        #expect(keyText([.key("name")]) == #""name""#)
        #expect(keyText([.key("hosts")]) == #""hosts""#)
        #expect(keyText([.key("hosts"), .index(0), .key("port")]) == #""port""#)
        #expect(keyText([.key("tls")]) == #""tls""#)
    }

    @Test func rootAndArrayElementsHaveNoKeyRange() throws {
        let document = try #require(parseDocument(nested))
        #expect(document.keyRange(of: .root) == nil)
        #expect(document.keyRange(of: [.key("hosts"), .index(0)]) == nil)
    }

    @Test func pathsThatLeadNowhereHaveNoRange() throws {
        let document = try #require(parseDocument(nested))
        #expect(document.range(of: [.key("missing")]) == nil)
        #expect(document.range(of: [.key("hosts"), .index(2)]) == nil)
        #expect(document.range(of: [.key("hosts"), .index(-1)]) == nil)
        #expect(document.range(of: [.key("hosts"), .key("x")]) == nil)
        #expect(document.range(of: [.key("name"), .index(0)]) == nil)
        #expect(document.keyRange(of: [.key("missing")]) == nil)
    }

    @Test func rangeLocationsAreLineAndColumnInScalars() throws {
        let document = try #require(parseDocument(nested))
        // Line 2 is `  "name": "café",`; the key starts at column 3.
        let key = try #require(document.keyRange(of: [.key("name")]))
        #expect(key.start.line == 2 && key.start.column == 3)
        #expect(key.end.line == 2 && key.end.column == 9)
        let name = try #require(document.range(of: [.key("name")]))
        #expect(name.start.line == 2 && name.start.column == 11)
        #expect(name.end.column == 17)  // "café" is 6 scalars with quotes, though 7 bytes
        #expect(name.end.offset - name.start.offset == 7)
        // The emoji line: columns count the emoji as one scalar, not four bytes.
        let host = try #require(document.range(of: [.key("hosts"), .index(1), .key("host")]))
        let port = try #require(document.range(of: [.key("hosts"), .index(1), .key("port")]))
        #expect(host.start.line == 5)
        #expect(port.start.line == 5)
        #expect(port.start.offset - host.end.offset == 10)  // `, "port": `
        #expect(port.start.column - host.end.column == 10)
    }

    @Test func multiLineContainerRange() throws {
        let document = try #require(parseDocument(nested))
        let hosts = try #require(document.range(of: [.key("hosts")]))
        #expect(hosts.start.line == 3)
        #expect(hosts.end.line == 6)
        #expect(hosts.end.column == 4)  // just past the `]`
    }

    @Test func everyValueAndKeyOfAParsedDocumentHasARange() throws {
        let document = try #require(parseDocument(nested))
        var visited = 0
        func walk(_ value: JSONValue, _ path: JSONPath, key: Bool) {
            visited += 1
            let range = document.range(of: path)
            #expect(range != nil, "\(path)")
            if key { #expect(document.keyRange(of: path) != nil, "\(path)") }
            switch value {
            case .array(let elements):
                for (index, element) in elements.enumerated() { walk(element, path.appending(index: index), key: false) }
            case .object(let object):
                for member in object { walk(member.value, path.appending(key: member.key), key: true) }
            default:
                break
            }
        }
        walk(document.value, .root, key: false)
        #expect(visited == 10)
    }

    @Test func childRangesNestInsideParentRanges() throws {
        let document = try #require(parseDocument(nested))
        let parent = try #require(document.range(of: [.key("hosts")]))
        let child = try #require(document.range(of: [.key("hosts"), .index(1), .key("port")]))
        #expect(parent.offsets.contains(child.start.offset))
        #expect(child.end.offset <= parent.end.offset)
    }

    @Test func rangesSurviveCommentsAndWhitespaceInJSONC() throws {
        let text = "{ /* c */ \"a\" /* k */ : /* v */ 12 /* end */ , // x\n \"b\": [ 1 , 2 , ] }"
        let document = try #require(parseDocument(text, .jsonc))
        #expect(document.range(of: [.key("a")]).flatMap { document.text(in: $0) } == "12")
        #expect(document.keyRange(of: [.key("a")]).flatMap { document.text(in: $0) } == "\"a\"")
        #expect(document.range(of: [.key("b"), .index(1)]).flatMap { document.text(in: $0) } == "2")
        #expect(document.range(of: [.key("b")]).flatMap { document.text(in: $0) } == "[ 1 , 2 , ]")
        #expect(document.range(of: [.key("b")])?.start.line == 2)
    }

    @Test func rangesWithABOMCountItInOffsetsButNotColumns() throws {
        let bytes = [0xEF, 0xBB, 0xBF] + Array("[7]".utf8)
        let document = try JSONDocument(parsing: bytes, options: JSONParseOptions(allowBOM: true))
        let range = try #require(document.range(of: [.index(0)]))
        #expect(range.start.offset == 4)
        #expect(range.start.column == 2)
        #expect(document.range.start.column == 1)
        #expect(document.source == bytes)
    }

    @Test func rangesWithEscapedKeysAndStrings() throws {
        let document = try #require(parseDocument(#"{"a\u0062":"x\ty"}"#))
        #expect(document.keyRange(of: [.key("ab")]).flatMap { document.text(in: $0) } == #""a\u0062""#)
        #expect(document.range(of: [.key("ab")]).flatMap { document.text(in: $0) } == #""x\ty""#)
    }

    @Test func rangesOfDuplicateKeysBelongToTheKeptOccurrence() throws {
        let text = #"{"a":1,"b":0,"a":22}"#
        let first = try #require(parseDocument(text, JSONParseOptions(duplicateKeys: .firstWins)))
        #expect(first.range(of: [.key("a")]).flatMap { first.text(in: $0) } == "1")
        #expect(first.keyRange(of: [.key("a")])?.start.offset == 1)
        let last = try #require(parseDocument(text, JSONParseOptions(duplicateKeys: .lastWins)))
        #expect(last.range(of: [.key("a")]).flatMap { last.text(in: $0) } == "22")
        #expect(last.keyRange(of: [.key("a")])?.start.offset == 13)
        // The member keeps its first position; its neighbours' ranges are untouched.
        #expect(last.value.object?.keyList == ["a", "b"])
        #expect(last.range(of: [.key("b")]).flatMap { last.text(in: $0) } == "0")
    }

    @Test func rangesInLargeDocumentsAreQueryableWithoutQuadraticCost() throws {
        let text = "[" + (0..<100_000).map(String.init).joined(separator: ",") + "]"
        let document = try #require(parseDocument(text))
        for index in stride(from: 0, to: 100_000, by: 997) {
            let range = try #require(document.range(of: [.index(index)]))
            #expect(document.text(in: range) == String(index))
        }
    }

    @Test func locationOfOffsetClampsAndMatchesRanges() throws {
        let document = try #require(parseDocument("[1,\n2]"))
        #expect(document.location(ofOffset: 0) == SourceLocation(offset: 0, line: 1, column: 1))
        #expect(document.location(ofOffset: 4) == SourceLocation(offset: 4, line: 2, column: 1))
        #expect(document.location(ofOffset: 100).offset == 6)
        #expect(document.location(ofOffset: -5).offset == 0)
    }

    @Test func textInRangeRejectsRangesOutsideTheSource() throws {
        let document = try #require(parseDocument("[1]"))
        let outside = SourceRange(
            start: SourceLocation(offset: 0, line: 1, column: 1),
            end: SourceLocation(offset: 50, line: 1, column: 51))
        #expect(document.text(in: outside) == nil)
    }

    @Test func scalarRootsHaveRanges() throws {
        let document = try #require(parseDocument("  \"hi\" "))
        #expect(document.text(in: document.range) == "\"hi\"")
        #expect(document.keyRange(of: .root) == nil)
    }

    @Test func documentValueMatchesValueParser() throws {
        let document = try #require(parseDocument(nested))
        #expect(document.value == (try JSONValue(parsing: nested)))
        #expect(document.value.value(at: [.key("hosts"), .index(0), .key("port")]) == 80)
    }
}
