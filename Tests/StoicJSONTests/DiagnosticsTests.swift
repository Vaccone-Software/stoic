import StoicJSON
import Testing

/// Where an error is reported matters as much as what it is: these assert
/// code, line, column, byte offset and path together.
struct Located: Sendable, CustomTestStringConvertible {
    var name: String
    var bytes: [UInt8]
    var options: JSONParseOptions
    var code: JSONParseError.Code
    var offset: Int
    var line: Int
    var column: Int
    var path: String
    var testDescription: String { name }

    init(
        _ name: String, _ text: String, _ options: JSONParseOptions = .strict,
        code: JSONParseError.Code, offset: Int, line: Int, column: Int, path: String = "$"
    ) {
        self.init(
            name, bytes: Array(text.utf8), options, code: code, offset: offset,
            line: line, column: column, path: path)
    }

    init(
        _ name: String, bytes: [UInt8], _ options: JSONParseOptions = .strict,
        code: JSONParseError.Code, offset: Int, line: Int, column: Int, path: String = "$"
    ) {
        self.name = name
        self.bytes = bytes
        self.options = options
        self.code = code
        self.offset = offset
        self.line = line
        self.column = column
        self.path = path
    }
}

let locatedCases: [Located] = [
    Located(
        "unexpected_on_third_line", "[1,\n  2,\n  x]",
        code: .unexpectedCharacter, offset: 11, line: 3, column: 3, path: "$[2]"),
    Located(
        "multibyte_before_error", "[\"\u{E9}\u{1F600}\", x]",
        code: .unexpectedCharacter, offset: 11, line: 1, column: 8, path: "$[1]"),
    Located(
        "crlf_lines_and_duplicate_key", "{\r\n  \"a\": 1,\r\n  \"a\": 2\r\n}",
        code: .duplicateKey, offset: 16, line: 3, column: 3, path: "$.a"),
    Located(
        "lone_cr_is_a_line_break", "[1,\r2,\rx]",
        code: .unexpectedCharacter, offset: 7, line: 3, column: 1, path: "$[2]"),
    Located(
        "lf_after_cr_is_one_break", "[1,\r\n2,\r\nx]",
        code: .unexpectedCharacter, offset: 9, line: 3, column: 1, path: "$[2]"),
    Located(
        "unterminated_string_points_at_its_start", "{\"a\": \"abc",
        code: .unterminatedString, offset: 6, line: 1, column: 7, path: "$.a"),
    Located(
        "unexpected_end_after_newline", "[1,\n",
        code: .unexpectedEnd, offset: 4, line: 2, column: 1, path: "$[1]"),
    Located(
        "leading_zero_points_at_the_extra_digit", "[1, 01]",
        code: .invalidNumber, offset: 5, line: 1, column: 6, path: "$[1]"),
    Located(
        "trailing_content_on_line_two", "{}\n  x",
        code: .trailingContent, offset: 5, line: 2, column: 3),
    Located(
        "invalid_escape_in_nested_key", #"{"a": {"b": "x\q"}}"#,
        code: .invalidEscape, offset: 14, line: 1, column: 15, path: "$.a.b"),
    Located(
        "lone_surrogate_points_at_the_escape", #""\uD800""#,
        code: .loneSurrogate, offset: 1, line: 1, column: 2),
    Located(
        "lone_surrogate_second_escape_blamed_on_first", #""ab\uD800A""#,
        code: .loneSurrogate, offset: 3, line: 1, column: 4),
    Located(
        "invalid_unicode_points_at_the_bad_digit", #""\u00G0""#,
        code: .invalidUnicode, offset: 5, line: 1, column: 6),
    Located(
        "invalid_utf8_after_multibyte", bytes: Array("[\"\u{E9}\", ".utf8) + [0xFF] + Array("]".utf8),
        code: .invalidUTF8, offset: 7, line: 1, column: 7, path: "$[1]"),
    Located(
        "invalid_utf8_inside_string_value", bytes: Array("{\"k\":\"\u{E9}".utf8) + [0xC0, 0x80, 0x22, 0x7D],
        code: .invalidUTF8, offset: 8, line: 1, column: 8, path: "$.k"),
    Located(
        "control_character_in_string_on_line_two", "[\n\"a\tb\"]",
        code: .controlCharacter, offset: 4, line: 2, column: 3, path: "$[0]"),
    Located(
        "size_limit_at_the_limit", "[1,2,3,4,5]",
        JSONParseOptions(maxBytes: 10),
        code: .sizeLimit, offset: 10, line: 1, column: 11),
    Located(
        "depth_limit_at_the_opening_bracket", "[[[1]]]",
        JSONParseOptions(maxDepth: 2),
        code: .depthLimit, offset: 2, line: 1, column: 3, path: "$[0][0]"),
    Located(
        "depth_limit_in_an_object", #"{"a":{"b":{}}}"#,
        JSONParseOptions(maxDepth: 2),
        code: .depthLimit, offset: 10, line: 1, column: 11, path: "$.a.b"),
    Located(
        "container_limit_on_the_extra_element", "[1,2,3]",
        JSONParseOptions(maxContainerCount: 2),
        code: .containerLimit, offset: 5, line: 1, column: 6, path: "$[2]"),
    Located(
        "container_limit_on_the_extra_member", #"{"a":1,"b":2,"c":3}"#,
        JSONParseOptions(maxContainerCount: 2),
        code: .containerLimit, offset: 13, line: 1, column: 14),
    Located(
        "string_limit_points_at_the_string", #"["", "abcde"]"#,
        JSONParseOptions(maxStringBytes: 4),
        code: .stringLimit, offset: 5, line: 1, column: 6, path: "$[1]"),
    Located(
        "unterminated_block_comment", "[1, /* x",
        JSONParseOptions(dialect: .jsonc),
        code: .unterminatedComment, offset: 4, line: 1, column: 5, path: "$[1]"),
    Located(
        "invalid_utf8_inside_a_comment", bytes: Array("[1, // ".utf8) + [0xC3, 0x28] + Array("\n]".utf8),
        JSONParseOptions(dialect: .jsonc),
        code: .invalidUTF8, offset: 7, line: 1, column: 8, path: "$[1]"),
    Located(
        "line_numbers_continue_through_block_comments", "[1,\n/* a\nb */\nx]",
        JSONParseOptions(dialect: .jsonc),
        code: .unexpectedCharacter, offset: 14, line: 4, column: 1, path: "$[1]"),
    Located(
        "bom_is_in_the_offset_but_not_the_column", bytes: [0xEF, 0xBB, 0xBF] + Array("[x]".utf8),
        JSONParseOptions(allowBOM: true),
        code: .unexpectedCharacter, offset: 4, line: 1, column: 2, path: "$[0]"),
    Located(
        "bom_rejected_at_offset_zero", bytes: [0xEF, 0xBB, 0xBF] + Array("[]".utf8),
        code: .byteOrderMark, offset: 0, line: 1, column: 1),
    Located(
        "trailing_comma_points_at_the_comma", "[1,\n 2,\n]",
        code: .trailingComma, offset: 6, line: 2, column: 3, path: "$[2]"),
    Located(
        "comment_in_strict_points_at_the_slash", "[1, // c\n2]",
        code: .commentNotAllowed, offset: 4, line: 1, column: 5, path: "$[1]"),
    Located(
        "number_overflow_points_at_the_number", "[true, 1e400]",
        code: .numberOutOfRange, offset: 7, line: 1, column: 8, path: "$[1]"),
    Located(
        "empty_input_after_whitespace", " \n ",
        code: .emptyInput, offset: 3, line: 2, column: 2),
    Located(
        "missing_colon_in_nested_object", #"{"a":{"b" 1}}"#,
        code: .unexpectedCharacter, offset: 10, line: 1, column: 11, path: "$.a.b"),
]

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test("error location and path", arguments: locatedCases)
    func located(_ input: Located) throws {
        let error = try #require(parse(input.bytes, input.options).error)
        #expect(error.code == input.code, "\(error)")
        #expect(error.location.offset == input.offset, "\(error)")
        #expect(error.location.line == input.line, "\(error)")
        #expect(error.location.column == input.column, "\(error)")
        #expect(error.path.description == input.path, "\(error)")
    }

    @Test func duplicateKeyNamesTheFirstOccurrence() throws {
        let error = try #require(parse("{\r\n  \"a\": 1,\r\n  \"a\": 2\r\n}").error)
        let first = try #require(error.related)
        #expect(first.offset == 5)
        #expect(first.line == 2)
        #expect(first.column == 3)
        #expect(error.message.contains("line 2, column 3"))
        #expect(error.message.contains("\"a\""))
    }

    @Test func messagesQuoteTheOffendingCharacter() throws {
        let error = try #require(parse("[1, \u{E9}]").error)
        #expect(error.message.contains("\u{E9}"))
        #expect(error.message.contains("U+00E9"))
    }

    @Test func controlCharactersAreNamedByCodePoint() throws {
        let error = try #require(parse("\"a\tb\"").error)
        #expect(error.message.contains("U+0009"))
    }

    @Test func descriptionCarriesCodeLocationPathAndMessage() throws {
        let error = try #require(parse("[1,\n x]").error)
        let text = error.description
        #expect(text.contains("unexpected_character"))
        #expect(text.contains("2:2"))
        #expect(text.contains("$[1]"))
    }

    @Test func codesAreStableStrings() {
        #expect(JSONParseError.Code.unexpectedCharacter.rawValue == "unexpected_character")
        #expect(JSONParseError.Code.unterminatedString.rawValue == "unterminated_string")
        #expect(JSONParseError.Code.invalidEscape.rawValue == "invalid_escape")
        #expect(JSONParseError.Code.invalidUnicode.rawValue == "invalid_unicode")
        #expect(JSONParseError.Code.loneSurrogate.rawValue == "lone_surrogate")
        #expect(JSONParseError.Code.invalidNumber.rawValue == "invalid_number")
        #expect(JSONParseError.Code.numberOutOfRange.rawValue == "number_out_of_range")
        #expect(JSONParseError.Code.duplicateKey.rawValue == "duplicate_key")
        #expect(JSONParseError.Code.depthLimit.rawValue == "depth_limit")
        #expect(JSONParseError.Code.sizeLimit.rawValue == "size_limit")
        #expect(JSONParseError.Code.stringLimit.rawValue == "string_limit")
        #expect(JSONParseError.Code.containerLimit.rawValue == "container_limit")
        #expect(JSONParseError.Code.trailingContent.rawValue == "trailing_content")
        #expect(JSONParseError.Code.emptyInput.rawValue == "empty_input")
        #expect(JSONParseError.Code.controlCharacter.rawValue == "control_character")
        #expect(JSONParseError.Code.invalidUTF8.rawValue == "invalid_utf8")
    }

    @Test func errorsAreHashableAndSendable() throws {
        let a = try #require(parse("[,]").error)
        let b = try #require(parse("[,]").error)
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
    }

    @Test func documentParseThrowsTheSameErrorAsValueParse() throws {
        let text = "[1,\n x]"
        let fromValue = try #require(parse(text).error)
        do throws(JSONParseError) {
            _ = try JSONDocument(parsing: text)
            Issue.record("expected a failure")
        } catch {
            #expect(error == fromValue)
        }
    }
}
