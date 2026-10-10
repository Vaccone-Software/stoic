import StoicJSON
import Testing

@Suite("Encoding")
struct EncodingTests {
    private func value(_ text: String) throws -> JSONValue {
        let outcome = parse(text)
        return try #require(outcome.value, "\(outcome.error.map(String.init(describing:)) ?? "")")
    }

    // MARK: Canonical

    @Test func canonicalSortsKeysAndRemovesWhitespace() throws {
        let v = try value(#"{ "b": [1, 2], "a": { "d": true, "c": null } }"#)
        #expect(v.encodedString(style: .canonical) == #"{"a":{"c":null,"d":true},"b":[1,2]}"#)
    }

    @Test func canonicalSortsByUTF16CodeUnitsLikeRFC8785() throws {
        // RFC 8785 section 3.2.3: the sorted order differs from UTF-8 byte order.
        let v = try value(#"""
            {"\u20ac":"Euro Sign","\r":"Carriage Return","\ufb33":"Hebrew Letter Dalet With Dagesh","1":"One","\ud83d\ude00":"Emoji: Grinning Face","\u0080":"Control","\u00f6":"Latin Small Letter O With Diaeresis"}
            """#)
        let keys = try #require(try value(v.encodedString()).object).keyList
        #expect(keys == ["\r", "1", "\u{80}", "\u{F6}", "\u{20AC}", "\u{1F600}", "\u{FB33}"])
    }

    @Test func canonicalRFC8785Sample() throws {
        // RFC 8785 section 3.2.4 (numbers that a double holds exactly).
        let v = try value(#"""
            {"numbers":[1E30,4.50,2e-3,0.000000000000000000000000001],"string":"\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/","literals":[null,true,false]}
            """#)
        #expect(
            v.encodedString()
                == #"{"literals":[null,true,false],"numbers":[1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}"#
        )
    }

    @Test func canonicalNumbersAreRewritten() throws {
        let v = try value("[1.0, 1E+2, -0, 0.10, 1e21, 9007199254740993]")
        #expect(v.encodedString() == "[1,100,0,0.1,1e+21,9007199254740993]")
    }

    @Test func canonicalIgnoresSourceOrder() throws {
        let a = try value(#"{"x":1,"y":{"p":1,"q":2}}"#)
        let b = try value(#"{"y":{"q":2,"p":1},"x":1}"#)
        #expect(a.encoded() == b.encoded())
    }

    // MARK: Compact and pretty

    @Test func compactKeepsSourceOrderAndSpelling() throws {
        let v = try value(#"{ "b": 1.0, "a": [1E2, true] }"#)
        #expect(v.encodedString(style: .compact) == #"{"b":1.0,"a":[1E2,true]}"#)
    }

    @Test func prettyPreservesSourceOrderAndSpelling() throws {
        let v = try value(#"{"b":1.0,"a":[1,{"c":[]}],"e":{}}"#)
        let expected = """
            {
              "b": 1.0,
              "a": [
                1,
                {
                  "c": []
                }
              ],
              "e": {}
            }
            """
        #expect(v.encodedString(style: .pretty(indent: 2)) == expected)
        #expect(v.encodedString(style: .pretty()) == expected)
    }

    @Test func prettyIndentWidth() throws {
        let v = try value(#"{"a":[1]}"#)
        #expect(v.encodedString(style: .pretty(indent: 4)) == "{\n    \"a\": [\n        1\n    ]\n}")
        #expect(v.encodedString(style: .pretty(indent: 0)) == "{\n\"a\": [\n1\n]\n}")
        #expect(v.encodedString(style: .pretty(indent: -3)) == "{\n\"a\": [\n1\n]\n}")
    }

    @Test func scalarsAndEmptyContainers() throws {
        for (text, expected) in [("null", "null"), ("true", "true"), ("false", "false"), ("42", "42"), (#""x""#, #""x""#), ("[]", "[]"), ("{}", "{}")] {
            let v = try value(text)
            #expect(v.encodedString(style: .canonical) == expected)
            #expect(v.encodedString(style: .compact) == expected)
            #expect(v.encodedString(style: .pretty()) == expected)
        }
    }

    // MARK: Strings

    @Test func stringsUseMinimalEscapes() {
        let v = JSONValue.string("\"\\/\u{8}\u{9}\u{A}\u{C}\u{D}\u{0}\u{1}\u{1F}\u{7F}\u{80}\u{2028}\u{1F600}")
        #expect(
            v.encodedString()
                == "\"\\\"\\\\/\\b\\t\\n\\f\\r\\u0000\\u0001\\u001f\u{7F}\u{80}\u{2028}\u{1F600}\"")
    }

    @Test func controlEscapesAreLowercaseHex() {
        let v = JSONValue.string("\u{1A}\u{1B}\u{1F}")
        #expect(v.encodedString() == "\"\\u001a\\u001b\\u001f\"")
    }

    @Test func keysAreEscapedLikeStrings() {
        let v: JSONValue = ["a\"b\n": 1]
        #expect(v.encodedString() == #"{"a\"b\n":1}"#)
    }

    @Test func nonASCIIIsWrittenAsUTF8() {
        let v = JSONValue.string("\u{E9}\u{1F600}")
        #expect(v.encoded() == [0x22, 0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80, 0x22])
    }

    // MARK: Round trips

    @Test(arguments: [JSONEncodingStyle.canonical, .compact, .pretty(indent: 2), .pretty(indent: 7)])
    func roundTripOfADenseDocument(_ style: JSONEncodingStyle) throws {
        let source = #"""
            {"s":"line\nbreak \"quoted\" \\ \u0000 \u001f \u00e9 \ud83d\ude00 \u2028","n":[0,-0,1.5e300,-2E-5,12345678901234567890,0.1],
             "o":{"":{"nested":[[],[[]],{}]},"\u00e9":null,"e\u0301":true},"b":[true,false,null]}
            """#
        let v = try value(source)
        #expect(try value(v.encodedString(style: style)) == v)
    }

    @Test func parsedAndEncodedKeysKeepTheirScalars() throws {
        let v = try value("{\"\u{E9}\":1,\"e\u{301}\":2}")
        let again = try value(v.encodedString(style: .canonical))
        #expect(again.object?.count == 2)
        #expect(again == v)
    }

    @Test func encodedBytesAndStringAgree() throws {
        let v = try value(#"{"a":[1,"é"]}"#)
        #expect(String(decoding: v.encoded(), as: UTF8.self) == v.encodedString())
    }

    @Test func canonicalBytesAreStableAcrossReparse() throws {
        let v = try value(#"{"z":1.50,"a":[1E2,-0],"m":{"y":"é","x":null}}"#)
        let once = v.encoded()
        let twice = try #require(parse(once).value).encoded()
        #expect(once == twice)
    }
}
