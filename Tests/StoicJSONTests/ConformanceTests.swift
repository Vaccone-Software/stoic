import StoicJSON
import Testing

// Accept/reject tables in the spirit of Nicolas Seriot's JSONTestSuite:
// `y_` cases must parse, `n_` cases must fail, and every failure carries the
// stable error code that says why. Inputs that need exact bytes are built
// from byte arrays so no source-file encoding can change them.

struct Accept: Sendable, CustomTestStringConvertible {
    var name: String
    var bytes: [UInt8]
    var expected: JSONValue?
    var testDescription: String { "y_" + name }

    init(_ name: String, _ text: String, _ expected: JSONValue? = nil) {
        self.name = name
        bytes = Array(text.utf8)
        self.expected = expected
    }

    init(_ name: String, bytes: [UInt8], _ expected: JSONValue? = nil) {
        self.name = name
        self.bytes = bytes
        self.expected = expected
    }
}

struct Reject: Sendable, CustomTestStringConvertible {
    var name: String
    var bytes: [UInt8]
    var code: JSONParseError.Code
    var testDescription: String { "n_" + name }

    init(_ name: String, _ text: String, _ code: JSONParseError.Code) {
        self.name = name
        bytes = Array(text.utf8)
        self.code = code
    }

    init(_ name: String, bytes: [UInt8], _ code: JSONParseError.Code) {
        self.name = name
        self.bytes = bytes
        self.code = code
    }
}

private func utf8(_ prefix: String = "", _ middle: [UInt8], _ suffix: String = "") -> [UInt8] {
    Array(prefix.utf8) + middle + Array(suffix.utf8)
}

private func quoted(_ middle: [UInt8]) -> [UInt8] { utf8("\"", middle, "\"") }

private func deepArrays(_ depth: Int) -> String {
    String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
}

let acceptCases: [Accept] = [
    // Structure
    Accept("array_empty", "[]", []),
    Accept("array_whitespace_everywhere", " \t\r\n[ \t\r\n1 \t\r\n, \t\r\n2 \t\r\n] \t\r\n", [1, 2]),
    Accept("array_nested", "[[],[[]]]", [[], [[]]]),
    Accept("array_mixed", #"[null,true,false,0,"s",[],{}]"#, [nil, true, false, 0, "s", [], [:]]),
    Accept("object_empty", "{}", [:]),
    Accept("object_whitespace", "{ \"a\" : 1 }", ["a": 1]),
    Accept("object_nested", #"{"a":{"b":{"c":[1,{"d":null}]}}}"#),
    Accept("object_empty_key", #"{"":1}"#, ["": 1]),
    Accept("object_escaped_key", #"{"a\u0062":1}"#, ["ab": 1]),
    Accept("object_keys_equal_only_canonically", "{\"\u{E9}\":1,\"e\u{301}\":2}"),
    Accept("object_member_named_proto", #"{"__proto__":1,"constructor":2}"#),
    Accept("depth_exactly_64", deepArrays(64)),

    // Scalars at the root (RFC 8259, not RFC 4627)
    Accept("root_null", "null", nil),
    Accept("root_true", "true", true),
    Accept("root_false", "false", false),
    Accept("root_string", #""x""#, "x"),
    Accept("root_number", "42", 42),
    Accept("root_whitespace_around", " \t\n\r null \t\n\r", nil),

    // Numbers
    Accept("number_zero", "0", 0),
    Accept("number_negative_zero", "-0", 0),
    Accept("number_negative", "-1", -1),
    Accept("number_fraction", "1.5", 1.5),
    Accept("number_zero_fraction", "0.0", 0),
    Accept("number_exponent_lower", "1e5", 100_000),
    Accept("number_exponent_upper", "1E5", 100_000),
    Accept("number_exponent_plus", "1e+5", 100_000),
    Accept("number_exponent_minus", "1e-2", 0.01),
    Accept("number_exponent_zero_leading", "1e005", 100_000),
    Accept("number_fraction_exponent", "-1.5e10", -15_000_000_000),
    Accept("number_zero_exponent", "0e0", 0),
    Accept("number_max_double", "1.7976931348623157e308"),
    Accept("number_min_subnormal", "5e-324"),
    Accept("number_big_integer_in_double_range", "123456789012345678901234567890"),
    Accept("number_in_array_then_close", "[1]", [1]),

    // Strings
    Accept("string_empty", #""""#, ""),
    Accept("string_simple_escapes", #""\"\\\/\b\f\n\r\t""#, "\"\\/\u{8}\u{C}\n\r\t"),
    Accept("string_unicode_escape", #""\u0041\u00e9\u00E9""#, "A\u{E9}\u{E9}"),
    Accept("string_nul_escape", #""\u0000""#, "\u{0}"),
    Accept("string_surrogate_pair", #""\uD83D\uDE00""#, "\u{1F600}"),
    Accept("string_surrogate_pair_lowercase", #""\ud83d\ude00""#, "\u{1F600}"),
    Accept("string_max_scalar_escaped", #""\uDBFF\uDFFF""#, "\u{10FFFF}"),
    Accept("string_two_pairs", #""\uD83D\uDE00\uD83D\uDE01""#, "\u{1F600}\u{1F601}"),
    Accept("string_utf8_2byte", "\"\u{E9}\"", "\u{E9}"),
    Accept("string_utf8_3byte", "\"\u{20AC}\"", "\u{20AC}"),
    Accept("string_utf8_4byte", "\"\u{1F600}\"", "\u{1F600}"),
    Accept("string_utf8_max_scalar", bytes: quoted([0xF4, 0x8F, 0xBF, 0xBF]), "\u{10FFFF}"),
    Accept("string_noncharacter_ffff", bytes: quoted([0xEF, 0xBF, 0xBF]), "\u{FFFF}"),
    Accept("string_replacement_character", bytes: quoted([0xEF, 0xBF, 0xBD]), "\u{FFFD}"),
    Accept("string_ed_9f_bf_is_not_a_surrogate", bytes: quoted([0xED, 0x9F, 0xBF]), "\u{D7FF}"),
    Accept("string_line_separator_raw", "\"\u{2028}\u{2029}\"", "\u{2028}\u{2029}"),
    Accept("string_del_raw", bytes: quoted([0x7F]), "\u{7F}"),
    Accept("string_bom_inside", bytes: quoted([0xEF, 0xBB, 0xBF]), "\u{FEFF}"),
    Accept("string_combining_sequence_kept", "\"e\u{301}\"", "e\u{301}"),

    // Literals around structure
    Accept("literal_adjacent_to_structure", "[true,false,null]", [true, false, nil]),
    Accept("literal_then_close", "{\"a\":true}", ["a": true]),
]

let rejectCases: [Reject] = [
    // Empty and truncated
    Reject("empty", "", .emptyInput),
    Reject("only_whitespace", " \t\r\n", .emptyInput),
    Reject("array_open", "[", .unexpectedEnd),
    Reject("array_after_value", "[1", .unexpectedEnd),
    Reject("array_after_comma", "[1,", .unexpectedEnd),
    Reject("object_open", "{", .unexpectedEnd),
    Reject("object_after_key", #"{"a""#, .unexpectedEnd),
    Reject("object_after_colon", #"{"a":"#, .unexpectedEnd),
    Reject("object_after_value", #"{"a":1"#, .unexpectedEnd),
    Reject("object_after_comma", #"{"a":1,"#, .unexpectedEnd),
    Reject("literal_truncated", "tru", .unexpectedEnd),
    Reject("literal_truncated_in_array", "[nul", .unexpectedEnd),

    // Punctuation
    Reject("array_double_comma", "[1,,2]", .unexpectedCharacter),
    Reject("array_leading_comma", "[,1]", .unexpectedCharacter),
    Reject("array_missing_comma", "[1 2]", .unexpectedCharacter),
    Reject("array_trailing_comma", "[1,]", .trailingComma),
    Reject("array_only_comma", "[,]", .unexpectedCharacter),
    Reject("array_closed_by_brace", "[1}", .unexpectedCharacter),
    Reject("object_trailing_comma", #"{"a":1,}"#, .trailingComma),
    Reject("object_leading_comma", #"{,"a":1}"#, .unexpectedCharacter),
    Reject("object_only_comma", "{,}", .unexpectedCharacter),
    Reject("object_closed_by_bracket", #"{"a":1]"#, .unexpectedCharacter),
    Reject("object_missing_value", #"{"a":}"#, .unexpectedCharacter),
    Reject("object_missing_colon", #"{"a" 1}"#, .unexpectedCharacter),
    Reject("object_no_colon_at_all", #"{"a"}"#, .unexpectedCharacter),
    Reject("object_numeric_key", "{1:2}", .unexpectedCharacter),
    Reject("object_unquoted_key", "{a:1}", .unexpectedCharacter),
    Reject("object_single_quoted_key", "{'a':1}", .unexpectedCharacter),
    Reject("object_missing_comma", #"{"a":1 "b":2}"#, .unexpectedCharacter),
    Reject("single_quoted_string", "['a']", .unexpectedCharacter),
    Reject("stray_colon", ":", .unexpectedCharacter),
    Reject("stray_closer", "]", .unexpectedCharacter),

    // Trailing content
    Reject("two_numbers", "1 2", .trailingContent),
    Reject("two_values", "{} []", .trailingContent),
    Reject("extra_closer", "[]]", .trailingContent),
    Reject("garbage_after_root", "null x", .trailingContent),
    Reject("nul_after_root", "{}\u{0}", .trailingContent),
    Reject("number_underscore_tail", "1_000", .trailingContent),

    // Comments belong to the .jsonc dialect only
    Reject("line_comment", "// c\n1", .commentNotAllowed),
    Reject("block_comment", "/* c */ 1", .commentNotAllowed),
    Reject("comment_in_array", "[1/**/]", .commentNotAllowed),
    Reject("comment_after_root", "1 // c", .commentNotAllowed),

    // Literals
    Reject("literal_capitalised", "True", .unexpectedCharacter),
    Reject("literal_mixed_case", "tRue", .unexpectedCharacter),
    Reject("literal_wrong_tail", "nul1", .unexpectedCharacter),
    Reject("literal_run_on", "[nulll]", .unexpectedCharacter),
    Reject("literal_run_on_word", "[truex]", .unexpectedCharacter),
    Reject("literal_run_on_literal", "truefalse", .unexpectedCharacter),
    Reject("literal_undefined", "undefined", .unexpectedCharacter),

    // Numbers
    Reject("number_leading_zero", "01", .invalidNumber),
    Reject("number_leading_zero_negative", "-01", .invalidNumber),
    Reject("number_leading_zeros_fraction", "00.5", .invalidNumber),
    Reject("number_plus", "+1", .invalidNumber),
    Reject("number_leading_dot", ".5", .invalidNumber),
    Reject("number_negative_leading_dot", "-.5", .invalidNumber),
    Reject("number_trailing_dot", "1.", .invalidNumber),
    Reject("number_dot_before_exponent", "1.e5", .invalidNumber),
    Reject("number_lone_minus", "-", .invalidNumber),
    Reject("number_double_minus", "--1", .invalidNumber),
    Reject("number_hex", "0x10", .invalidNumber),
    Reject("number_binary", "0b1", .invalidNumber),
    Reject("number_exponent_no_digits", "1e", .invalidNumber),
    Reject("number_exponent_sign_no_digits", "1e+", .invalidNumber),
    Reject("number_two_dots", "1.5.3", .invalidNumber),
    Reject("number_two_exponents", "1e5e3", .invalidNumber),
    Reject("number_exponent_fraction", "1e1.5", .invalidNumber),
    Reject("number_nan", "NaN", .invalidNumber),
    Reject("number_infinity", "Infinity", .invalidNumber),
    Reject("number_negative_infinity", "-Infinity", .invalidNumber),
    Reject("number_minus_nan", "-NaN", .invalidNumber),
    Reject("number_in_array_bad", "[1.]", .invalidNumber),
    Reject("number_overflow", "1e400", .numberOutOfRange),
    Reject("number_overflow_negative", "-1e400", .numberOutOfRange),
    Reject("number_underflow", "1E-400", .numberOutOfRange),
    Reject("number_underflow_just_below_min", "1e-324", .numberOutOfRange),
    Reject("number_huge_exponent", "1e99999999999999999999", .numberOutOfRange),
    Reject("number_huge_integer", String(repeating: "9", count: 400), .numberOutOfRange),
    Reject("number_long_decimal_underflow", "0." + String(repeating: "0", count: 400) + "1", .numberOutOfRange),

    // Strings
    Reject("string_unterminated", #""abc"#, .unterminatedString),
    Reject("string_only_quote", "\"", .unterminatedString),
    Reject("string_ends_after_backslash", #""\"#, .unterminatedString),
    Reject("string_escaped_quote_unterminated", #""\""#, .unterminatedString),
    Reject("string_unterminated_unicode_escape", #""\u12"#, .unterminatedString),
    Reject("string_invalid_escape_letter", #""\x""#, .invalidEscape),
    Reject("string_invalid_escape_single_quote", #""\'""#, .invalidEscape),
    Reject("string_invalid_escape_a", #""\a""#, .invalidEscape),
    Reject("string_invalid_escape_uppercase_u", #""\U0041""#, .invalidEscape),
    Reject("string_invalid_escape_nonascii", "\"\\\u{E9}\"", .invalidEscape),
    Reject("string_short_unicode_escape", #""\u12""#, .invalidUnicode),
    Reject("string_unicode_escape_not_hex", #""\uZZZZ""#, .invalidUnicode),
    Reject("string_unicode_escape_partly_hex", #""\u00G0""#, .invalidUnicode),
    Reject("string_unicode_escape_with_space", #""\u 123""#, .invalidUnicode),
    Reject("string_raw_newline", "\"a\nb\"", .controlCharacter),
    Reject("string_raw_tab", "\"a\tb\"", .controlCharacter),
    Reject("string_raw_cr", "\"a\rb\"", .controlCharacter),
    Reject("string_raw_nul", bytes: quoted([0x00]), .controlCharacter),
    Reject("string_raw_0x1f", bytes: quoted([0x1F]), .controlCharacter),
    Reject("string_raw_backspace", bytes: quoted([0x08]), .controlCharacter),
    Reject("key_raw_newline", "{\"a\nb\":1}", .controlCharacter),
    Reject("string_lone_high_surrogate", #""\uD800""#, .loneSurrogate),
    Reject("string_lone_low_surrogate", #""\uDC00""#, .loneSurrogate),
    Reject("string_high_then_plain_escape", #""\uD800\u0041""#, .loneSurrogate),
    Reject("string_high_then_character", #""\uD800x""#, .loneSurrogate),
    Reject("string_high_then_high", #""\uD800\uD800""#, .loneSurrogate),
    Reject("string_pair_in_wrong_order", #""\uDC00\uD800""#, .loneSurrogate),
    Reject("string_high_then_other_escape", #""\uD800\n""#, .loneSurrogate),
    Reject("string_high_surrogate_max", #""\uDBFF""#, .loneSurrogate),
    Reject("string_low_surrogate_max", #""\uDFFF""#, .loneSurrogate),
    Reject("key_lone_surrogate", #"{"\uD800":1}"#, .loneSurrogate),
    Reject("string_high_then_bad_hex", #""\uD800\uZZZZ""#, .invalidUnicode),

    // Invalid UTF-8, inside strings
    Reject("utf8_overlong_2byte_c0", bytes: quoted([0xC0, 0x80]), .invalidUTF8),
    Reject("utf8_overlong_2byte_c1", bytes: quoted([0xC1, 0xBF]), .invalidUTF8),
    Reject("utf8_overlong_3byte", bytes: quoted([0xE0, 0x80, 0x80]), .invalidUTF8),
    Reject("utf8_overlong_3byte_e0_9f", bytes: quoted([0xE0, 0x9F, 0xBF]), .invalidUTF8),
    Reject("utf8_overlong_4byte", bytes: quoted([0xF0, 0x80, 0x80, 0x80]), .invalidUTF8),
    Reject("utf8_overlong_4byte_f0_8f", bytes: quoted([0xF0, 0x8F, 0xBF, 0xBF]), .invalidUTF8),
    Reject("utf8_overlong_nul", bytes: quoted([0xC0, 0x80]), .invalidUTF8),
    Reject("utf8_encoded_surrogate_low_end", bytes: quoted([0xED, 0xA0, 0x80]), .invalidUTF8),
    Reject("utf8_encoded_surrogate_high_end", bytes: quoted([0xED, 0xBF, 0xBF]), .invalidUTF8),
    Reject("utf8_encoded_surrogate_pair", bytes: quoted([0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80]), .invalidUTF8),
    Reject("utf8_above_max_scalar", bytes: quoted([0xF4, 0x90, 0x80, 0x80]), .invalidUTF8),
    Reject("utf8_lead_f5", bytes: quoted([0xF5, 0x80, 0x80, 0x80]), .invalidUTF8),
    Reject("utf8_lead_f8", bytes: quoted([0xF8, 0x88, 0x80, 0x80, 0x80]), .invalidUTF8),
    Reject("utf8_lead_fe", bytes: quoted([0xFE]), .invalidUTF8),
    Reject("utf8_lead_ff", bytes: quoted([0xFF]), .invalidUTF8),
    Reject("utf8_stray_continuation", bytes: quoted([0x80]), .invalidUTF8),
    Reject("utf8_stray_continuation_bf", bytes: quoted([0xBF]), .invalidUTF8),
    Reject("utf8_2byte_missing_continuation", bytes: quoted([0xC3]), .invalidUTF8),
    Reject("utf8_2byte_followed_by_ascii", bytes: quoted([0xC3, 0x28]), .invalidUTF8),
    Reject("utf8_3byte_truncated", bytes: quoted([0xE2, 0x82]), .invalidUTF8),
    Reject("utf8_3byte_second_byte_bad", bytes: quoted([0xE2, 0x28, 0xA1]), .invalidUTF8),
    Reject("utf8_3byte_third_byte_bad", bytes: quoted([0xE2, 0x82, 0x28]), .invalidUTF8),
    Reject("utf8_4byte_truncated", bytes: quoted([0xF0, 0x9F, 0x98]), .invalidUTF8),
    Reject("utf8_4byte_fourth_byte_bad", bytes: quoted([0xF0, 0x9F, 0x98, 0x28]), .invalidUTF8),
    Reject("utf8_truncated_at_end_of_input", bytes: utf8("\"", [0xE2, 0x82]), .invalidUTF8),
    Reject("utf8_invalid_in_key", bytes: utf8("{\"", [0xFF], "\":1}"), .invalidUTF8),

    // Invalid UTF-8 and BOM, outside strings
    Reject("utf8_invalid_between_tokens", bytes: utf8("[", [0xFF], "]"), .invalidUTF8),
    Reject("utf8_invalid_after_root", bytes: utf8("1 ", [0xC0]), .trailingContent),
    Reject("bom_not_allowed", bytes: [0xEF, 0xBB, 0xBF] + Array("[]".utf8), .byteOrderMark),
    Reject("bom_in_the_middle", bytes: utf8("[", [0xEF, 0xBB, 0xBF], "]"), .unexpectedCharacter),
    Reject("nonascii_valid_outside_string", "[\u{E9}]", .unexpectedCharacter),
    Reject("nonascii_valid_bare_key", "{\u{E9}:1}", .unexpectedCharacter),

    // Whitespace that JSON does not define
    Reject("vertical_tab_is_not_whitespace", "[1,\u{0B}2]", .unexpectedCharacter),
    Reject("form_feed_is_not_whitespace", "[1,\u{0C}2]", .unexpectedCharacter),
    Reject("nbsp_is_not_whitespace", "[1,\u{A0}2]", .unexpectedCharacter),
    Reject("line_separator_is_not_whitespace", "[1,\u{2028}2]", .unexpectedCharacter),
    Reject("nul_is_not_whitespace", "[1,\u{0}2]", .unexpectedCharacter),

    // Duplicate keys, by default
    Reject("duplicate_key", #"{"a":1,"a":2}"#, .duplicateKey),
    Reject("duplicate_key_via_escape", #"{"a":1,"\u0061":2}"#, .duplicateKey),
    Reject("duplicate_key_nested", #"{"x":{"a":1,"b":2,"a":3}}"#, .duplicateKey),
    Reject("duplicate_key_non_adjacent", #"{"a":1,"b":2,"c":3,"a":4}"#, .duplicateKey),
    Reject("duplicate_empty_key", #"{"":1,"":2}"#, .duplicateKey),

    // Depth
    Reject("depth_65", deepArrays(65), .depthLimit),
]

@Suite("Conformance")
struct ConformanceTests {
    @Test("accepted", arguments: acceptCases)
    func accepted(_ input: Accept) throws {
        let outcome = parse(input.bytes)
        let value = try #require(outcome.value, "\(outcome.error.map(String.init(describing:)) ?? "")")
        if let expected = input.expected {
            #expect(value == expected)
        }
        // Whatever was accepted must survive a trip through every style.
        for style in [JSONEncodingStyle.canonical, .compact, .pretty(indent: 2)] {
            let again = parse(value.encoded(style: style))
            #expect(again.value == value, "style \(style)")
        }
    }

    @Test("rejected", arguments: rejectCases)
    func rejected(_ input: Reject) throws {
        let outcome = parse(input.bytes)
        let error = try #require(outcome.error, "unexpectedly parsed as \(String(describing: outcome.value))")
        #expect(error.code == input.code, "\(error)")
        #expect(error.location.offset >= 0 && error.location.offset <= input.bytes.count)
        #expect(!error.message.isEmpty)
    }

    @Test func tableSizes() {
        // The brief asks for a broad table; keep it from silently shrinking.
        #expect(acceptCases.count + rejectCases.count >= 200)
    }

    @Test func caseNamesAreUnique() {
        #expect(Set(acceptCases.map(\.name)).count == acceptCases.count)
        #expect(Set(rejectCases.map(\.name)).count == rejectCases.count)
    }

    // MARK: Behaviours the tables cannot say

    @Test func canonicallyEquivalentKeysAreDistinct() throws {
        let value = try #require(parse("{\"\u{E9}\":1,\"e\u{301}\":2}").value)
        let object = try #require(value.object)
        #expect(object.count == 2)
        #expect(object["\u{E9}"] == 1)
        #expect(object["e\u{301}"] == 2)
    }

    @Test func canonicallyEquivalentStringsAreNotEqual() {
        #expect(JSONValue.string("\u{E9}") != JSONValue.string("e\u{301}"))
        #expect(JSONValue.string("\u{E9}") == JSONValue.string("\u{E9}"))
    }

    @Test func parserAcceptsNulInKeysAndValues() throws {
        let value = try #require(parse(#"{"a\u0000b":"\u0000"}"#).value)
        #expect(value.object?["a\u{0}b"] == "\u{0}")
    }

    @Test func stringEscapesDecodeToTheRightScalars() throws {
        let value = try #require(parse(#""\uD834\uDD1E""#).value)
        #expect(value.string?.unicodeScalars.map(\.value) == [0x1D11E])
    }

    @Test func stringConvenienceAndBytesAgree() throws {
        let text = #"{"a":[1,2,{"b":"c"}]}"#
        let fromString = try JSONValue(parsing: text)
        let fromBytes = try JSONValue(parsing: Array(text.utf8))
        let fromSlice = try JSONValue(parsing: Array(text.utf8)[...])
        #expect(fromString == fromBytes)
        #expect(fromString == fromSlice)
    }

    @Test func documentAndValueParsersAgree() throws {
        let text = #"{"a":[1,2,{"b":"c"}],"d":null}"#
        let document = try JSONDocument(parsing: text)
        #expect(document.value == (try JSONValue(parsing: text)))
    }
}
