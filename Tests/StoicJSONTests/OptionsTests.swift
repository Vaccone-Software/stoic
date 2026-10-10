import StoicJSON
import Testing

@Suite("Options")
struct OptionsTests {
    // MARK: Duplicate keys

    @Test func duplicateKeysAreRejectedByDefault() throws {
        let error = try #require(parse(#"{"a":1,"b":2,"a":3}"#).error)
        #expect(error.code == .duplicateKey)
        #expect(JSONParseOptions().duplicateKeys == .reject)
    }

    @Test func firstWinsKeepsTheFirstValueAndPosition() throws {
        let options = JSONParseOptions(duplicateKeys: .firstWins)
        let object = try #require(parse(#"{"a":1,"b":2,"a":3}"#, options).value?.object)
        #expect(object["a"] == 1)
        #expect(object.keyList == ["a", "b"])
    }

    @Test func lastWinsKeepsTheLastValueInTheFirstPosition() throws {
        let options = JSONParseOptions(duplicateKeys: .lastWins)
        let object = try #require(parse(#"{"a":1,"b":2,"a":3}"#, options).value?.object)
        #expect(object["a"] == 3)
        #expect(object.keyList == ["a", "b"])
        #expect(object.count == 2)
    }

    @Test(arguments: [JSONParseOptions.DuplicateKeys.firstWins, .lastWins])
    func discardedDuplicatesAreStillValidated(_ policy: JSONParseOptions.DuplicateKeys) throws {
        let options = JSONParseOptions(duplicateKeys: policy)
        // The dropped value must be well-formed, and must still obey limits.
        #expect(parse(#"{"a":1,"a":[1,}"#, options).error?.code == .unexpectedCharacter)
        #expect(parse(#"{"a":1,"a":01}"#, options).error?.code == .invalidNumber)
        #expect(parse(#"{"a":1,"a":1e999}"#, options).error?.code == .numberOutOfRange)
        let tight = JSONParseOptions(duplicateKeys: policy, maxDepth: 1)
        #expect(parse(#"{"a":1,"a":[[]]}"#, tight).error?.code == .depthLimit)
    }

    @Test(arguments: [JSONParseOptions.DuplicateKeys.firstWins, .lastWins])
    func duplicatesInNestedObjectsAreResolvedToo(_ policy: JSONParseOptions.DuplicateKeys) throws {
        let options = JSONParseOptions(duplicateKeys: policy)
        let value = try #require(parse(#"{"x":{"a":1,"a":2},"y":[{"b":1,"b":2}]}"#, options).value)
        let expected = policy == .firstWins ? 1 : 2
        #expect(value.value(at: ["x", "a"].path) == JSONValue(integerLiteral: expected))
        #expect(value.value(at: JSONPath([.key("y"), .index(0), .key("b")])) == JSONValue(integerLiteral: expected))
    }

    @Test func duplicatesAreMatchedByScalarsNotByCanonicalEquivalence() throws {
        // Two keys that Swift calls equal are not duplicates of each other.
        let value = try #require(parse("{\"\u{E9}\":1,\"e\u{301}\":2}").value?.object)
        #expect(value.count == 2)
    }

    @Test func sameKeyInDifferentObjectsIsNotADuplicate() {
        #expect(parse(#"[{"a":1},{"a":2}]"#).value != nil)
        #expect(parse(#"{"a":{"a":1}}"#).value != nil)
    }

    // MARK: Dialects

    @Test func jsoncAcceptsComments() throws {
        let text = """
            // header
            {
              /* block
                 comment */
              "a": 1, // trailing
              "b": [1, /* inline */ 2],
            }
            // footer
            """
        let value = try #require(parse(text, .jsonc).value)
        #expect(value == ["a": 1, "b": [1, 2]])
    }

    @Test func jsoncAcceptsTrailingCommas() throws {
        #expect(parse("[1,2,]", .jsonc).value == [1, 2])
        #expect(parse(#"{"a":1,}"#, .jsonc).value == ["a": 1])
        #expect(parse("[[1,],]", .jsonc).value == [[1]])
        #expect(parse("[1,/* c */]", .jsonc).value == [1])
    }

    @Test(arguments: ["[,]", "[1,,]", "[,1]", "{,}", #"{"a":1,,}"#, "[1,,2]"])
    func jsoncStillRejectsOtherCommaMistakes(_ text: String) {
        #expect(parse(text, .jsonc).error != nil)
    }

    @Test func strictRejectsWhatJsoncAccepts() {
        #expect(parse("[1,]").error?.code == .trailingComma)
        #expect(parse("// x\n1").error?.code == .commentNotAllowed)
        #expect(parse("1 /* x */").error?.code == .commentNotAllowed)
    }

    @Test func jsoncCommentsDoNotHideDuplicatesOrContent() {
        #expect(parse(#"{"a":1,/*x*/"a":2}"#, .jsonc).error?.code == .duplicateKey)
        #expect(parse("1 // ok\n2", .jsonc).error?.code == .trailingContent)
    }

    @Test func jsoncLoneSlashIsNotAComment() {
        #expect(parse("[1, /]", .jsonc).error?.code == .unexpectedCharacter)
        #expect(parse("/", .jsonc).error?.code == .unexpectedCharacter)
        #expect(parse("[1/*", .jsonc).error?.code == .unterminatedComment)
    }

    @Test func jsoncCommentIsNotRecognisedInsideStrings() throws {
        #expect(parse(#"["// not a comment","/* nor this */"]"#, .jsonc).value == ["// not a comment", "/* nor this */"])
    }

    @Test func jsoncCommentOnlyInputIsEmpty() {
        #expect(parse("// nothing\n/* here */", .jsonc).error?.code == .emptyInput)
    }

    @Test func jsoncLineCommentEndsAtCarriageReturn() throws {
        #expect(parse("[1, // c\r2]", .jsonc).value == [1, 2])
    }

    @Test func jsoncLineCommentAtEndOfInput() {
        #expect(parse("1 // end", .jsonc).value == 1)
    }

    @Test func jsoncAllowsNonASCIIInComments() {
        #expect(parse("[1, // caf\u{E9} \u{1F600}\n2]", .jsonc).value == [1, 2])
    }

    // MARK: BOM

    @Test func bomIsSkippedWhenAllowed() throws {
        let bytes = [0xEF, 0xBB, 0xBF] + Array("[1]".utf8)
        #expect(parse(bytes, JSONParseOptions(allowBOM: true)).value == [1])
        #expect(parse(bytes, .jsonc).value == [1])
        #expect(parse(bytes).error?.code == .byteOrderMark)
    }

    @Test func bomAloneIsEmptyInput() {
        #expect(parse([0xEF, 0xBB, 0xBF], JSONParseOptions(allowBOM: true)).error?.code == .emptyInput)
    }

    @Test func onlyOneLeadingBomIsSkipped() {
        let bytes = [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + Array("1".utf8)
        #expect(parse(bytes, JSONParseOptions(allowBOM: true)).error != nil)
    }

    // MARK: Limits: the limit is accepted, one past it is rejected

    @Test func maxDepthBoundary() {
        func nested(_ depth: Int) -> String {
            String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        }
        #expect(parse(nested(64)).value != nil)
        #expect(parse(nested(65)).error?.code == .depthLimit)
        let options = JSONParseOptions(maxDepth: 3)
        #expect(parse(nested(3), options).value != nil)
        #expect(parse(nested(4), options).error?.code == .depthLimit)
    }

    @Test func maxDepthCountsObjectsAndArraysAlike() {
        let options = JSONParseOptions(maxDepth: 3)
        #expect(parse(#"{"a":[{"b":1}]}"#, options).value != nil)
        #expect(parse(#"{"a":[{"b":[]}]}"#, options).error?.code == .depthLimit)
    }

    @Test func maxDepthZeroAllowsOnlyScalars() {
        let options = JSONParseOptions(maxDepth: 0)
        #expect(parse("1", options).value != nil)
        #expect(parse("[]", options).error?.code == .depthLimit)
        #expect(parse("{}", options).error?.code == .depthLimit)
    }

    @Test func depthIsMeasuredAlongOnePathNotInTotal() {
        // Many siblings at depth 1 are not depth.
        let text = "[" + Array(repeating: "[]", count: 500).joined(separator: ",") + "]"
        #expect(parse(text, JSONParseOptions(maxDepth: 2)).value != nil)
    }

    @Test func maxBytesBoundary() {
        let text = "[1,2,3,4,5]"
        #expect(text.utf8.count == 11)
        #expect(parse(text, JSONParseOptions(maxBytes: 11)).value != nil)
        let error = parse(text, JSONParseOptions(maxBytes: 10)).error
        #expect(error?.code == .sizeLimit)
        #expect(error?.location.offset == 10)
    }

    @Test func maxBytesCountsTheBOM() {
        let bytes = [0xEF, 0xBB, 0xBF] + Array("[]".utf8)
        #expect(parse(bytes, JSONParseOptions(allowBOM: true, maxBytes: 5)).value != nil)
        #expect(parse(bytes, JSONParseOptions(allowBOM: true, maxBytes: 4)).error?.code == .sizeLimit)
    }

    @Test func maxBytesFailsBeforeReadingAnything() {
        // The size check wins over a syntax error later in the input.
        let error = parse("[1,2,3,4,5,6,7,8,9,x", JSONParseOptions(maxBytes: 5)).error
        #expect(error?.code == .sizeLimit)
    }

    @Test func defaultMaxBytesIsEightMiB() {
        #expect(JSONParseOptions().maxBytes == 8 * 1024 * 1024)
        let big = [UInt8](repeating: 0x20, count: 8 * 1024 * 1024) + Array("1".utf8)
        #expect(parse(big).error?.code == .sizeLimit)
        let fits = [UInt8](repeating: 0x20, count: 8 * 1024 * 1024 - 1) + Array("1".utf8)
        #expect(parse(fits).value == 1)
    }

    @Test func maxStringBytesBoundary() {
        let options = JSONParseOptions(maxStringBytes: 8)
        func string(_ count: Int) -> String { "\"" + String(repeating: "a", count: count) + "\"" }
        #expect(parse(string(8), options).value != nil)
        #expect(parse(string(9), options).error?.code == .stringLimit)
    }

    @Test func maxStringBytesCountsDecodedUTF8() {
        let options = JSONParseOptions(maxStringBytes: 4)
        #expect(parse("\"\u{1F600}\"", options).value != nil)  // 4 bytes
        #expect(parse("\"\u{1F600}a\"", options).error?.code == .stringLimit)
        #expect(parse(#""\uD83D\uDE00""#, options).value != nil)  // escapes decode to 4 bytes
        #expect(parse(#""\u00e9\u00e9""#, options).value != nil)  // 2 + 2
        #expect(parse(#""\u00e9\u00e9a""#, options).error?.code == .stringLimit)
        // Six source bytes decode to one: the decoded size is what is limited.
        #expect(parse(#""\u0061\u0061\u0061\u0061""#, options).value != nil)
    }

    @Test func maxStringBytesAppliesToKeys() {
        let options = JSONParseOptions(maxStringBytes: 3)
        #expect(parse(#"{"abc":1}"#, options).value != nil)
        #expect(parse(#"{"abcd":1}"#, options).error?.code == .stringLimit)
    }

    @Test func defaultMaxStringBytesIsOneMiB() {
        let limit = 1024 * 1024
        let fits = "\"" + String(repeating: "a", count: limit) + "\""
        let over = "\"" + String(repeating: "a", count: limit + 1) + "\""
        let roomy = JSONParseOptions(maxBytes: 4 * limit)
        #expect(parse(fits, roomy).value != nil)
        #expect(parse(over, roomy).error?.code == .stringLimit)
    }

    @Test func maxContainerCountBoundaryForArrays() {
        let options = JSONParseOptions(maxContainerCount: 3)
        #expect(parse("[1,2,3]", options).value != nil)
        #expect(parse("[1,2,3,4]", options).error?.code == .containerLimit)
        #expect(parse("[]", options).value != nil)
    }

    @Test func maxContainerCountBoundaryForObjects() {
        let options = JSONParseOptions(maxContainerCount: 3)
        #expect(parse(#"{"a":1,"b":2,"c":3}"#, options).value != nil)
        #expect(parse(#"{"a":1,"b":2,"c":3,"d":4}"#, options).error?.code == .containerLimit)
    }

    @Test func maxContainerCountIsPerContainer() {
        let options = JSONParseOptions(maxContainerCount: 2)
        #expect(parse("[[1,2],[3,4]]", options).value != nil)
        #expect(parse("[[1,2,3]]", options).error?.code == .containerLimit)
    }

    @Test func maxContainerCountZeroAllowsOnlyEmptyContainers() {
        let options = JSONParseOptions(maxContainerCount: 0)
        #expect(parse("[]", options).value != nil)
        #expect(parse("{}", options).value != nil)
        #expect(parse("[1]", options).error?.code == .containerLimit)
        #expect(parse(#"{"a":1}"#, options).error?.code == .containerLimit)
    }

    @Test func maxContainerCountAppliesWithTrailingCommaInJSONC() {
        let options = JSONParseOptions(dialect: .jsonc, maxContainerCount: 2)
        #expect(parse("[1,2,]", options).value != nil)
        #expect(parse("[1,2,3]", options).error?.code == .containerLimit)
    }

    @Test func defaultsAreWhatTheDesignSays() {
        let options = JSONParseOptions()
        #expect(options.dialect == .strict)
        #expect(options.duplicateKeys == .reject)
        #expect(options.allowBOM == false)
        #expect(options.maxDepth == 64)
        #expect(options.maxBytes == 8 * 1024 * 1024)
        #expect(options.maxStringBytes == 1024 * 1024)
        #expect(options.maxContainerCount == 100_000)
        #expect(JSONParseOptions.strict == options)
        #expect(JSONParseOptions.jsonc.dialect == .jsonc)
    }

    @Test func containerCountDefaultAtTheBoundary() throws {
        let fits = "[" + Array(repeating: "0", count: 100_000).joined(separator: ",") + "]"
        let over = "[" + Array(repeating: "0", count: 100_001).joined(separator: ",") + "]"
        let value = try #require(parse(fits).value)
        #expect(value.array?.count == 100_000)
        #expect(parse(over).error?.code == .containerLimit)
    }

    @Test func largeObjectParsesInReasonableTime() throws {
        // 100,000 members: a quadratic duplicate check would take minutes.
        var text = "{"
        for index in 0..<100_000 {
            if index > 0 { text += "," }
            text += "\"k\(index)\":\(index)"
        }
        text += "}"
        let object = try #require(parse(text).value?.object)
        #expect(object.count == 100_000)
        #expect(object["k99999"] == 99_999)
        #expect(object.index(forKey: "k0") == 0)
    }

    // MARK: Depth and the stack

    @Test func hundredThousandDeepArraysFailFastWithDepthLimit() throws {
        let bytes = [UInt8](repeating: UInt8(ascii: "["), count: 100_000)
        let error = try #require(parse(bytes).error)
        #expect(error.code == .depthLimit)
        #expect(error.location.offset == 64)
        #expect(error.path.count == 64)
    }

    @Test func hundredThousandDeepObjectsFailFastWithDepthLimit() throws {
        let bytes = Array(String(repeating: #"{"a":"#, count: 100_000).utf8)
        let error = try #require(parse(bytes).error)
        #expect(error.code == .depthLimit)
        #expect(error.path.count == 64)
    }

    @Test func hundredThousandDeepArraysFailFastInDocumentParsingToo() {
        let bytes = [UInt8](repeating: UInt8(ascii: "["), count: 100_000)
        do throws(JSONParseError) {
            _ = try JSONDocument(parsing: bytes)
            Issue.record("expected depth_limit")
        } catch {
            #expect(error.code == .depthLimit)
        }
    }

    @Test func closingBracketsWithoutOpenersAreRejected() {
        let bytes = [UInt8](repeating: UInt8(ascii: "]"), count: 100_000)
        #expect(parse(bytes).error?.code == .unexpectedCharacter)
    }

    @Test func parserUsesNoRecursion() throws {
        // A thousand levels is far beyond what a recursive parser could be
        // trusted with on a small stack; the explicit stack does not care.
        let depth = 1000
        let text = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        let value = try #require(parse(text, JSONParseOptions(maxDepth: depth)).value)
        var current = value
        var seen = 0
        while case .array(let elements) = current {
            seen += 1
            current = elements[0]
        }
        #expect(seen == depth)
        #expect(current == 1)
        #expect(parse(text, JSONParseOptions(maxDepth: depth - 1)).error?.code == .depthLimit)
    }
}

extension Array where Element == String {
    fileprivate var path: JSONPath { JSONPath(map { JSONPath.Component.key($0) }) }
}
