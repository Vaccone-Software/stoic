import StoicJSON
import Testing

// Property-style tests on a small seeded generator. Every failure message
// names its seed, so a failing case replays exactly.

/// Builds random JSON values that exercise the awkward corners: escapes,
/// control characters, astral scalars, canonically equivalent keys, numbers
/// of every shape.
struct JSONGenerator {
    var random: SeededGenerator

    init(seed: UInt64) {
        random = SeededGenerator(seed: seed)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &random)
    }

    mutating func chance(_ percent: Int) -> Bool {
        int(1...100) <= percent
    }

    mutating func scalar() -> Unicode.Scalar {
        let special: [UInt32] = [
            0x22, 0x5C, 0x2F, 0x00, 0x01, 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x1F, 0x7F, 0x80,
            0xE9, 0x301, 0x2028, 0x2029, 0xFEFF, 0xFFFD, 0xFFFF, 0xD7FF, 0xE000,
            0x1F600, 0x10000, 0x10FFFF,
        ]
        switch int(0...3) {
        case 0:
            return Unicode.Scalar(special[int(0...special.count - 1)]) ?? "?"
        case 1:
            return Unicode.Scalar(UInt8(int(0x20...0x7E)))
        case 2:
            // A BMP scalar outside the surrogate block.
            var value = UInt32(int(0...0xFFFF))
            if (0xD800...0xDFFF).contains(value) { value -= 0x800 }
            return Unicode.Scalar(value) ?? "?"
        default:
            return Unicode.Scalar(UInt32(int(0x10000...0x10FFFF))) ?? "?"
        }
    }

    mutating func string() -> String {
        var text = String.UnicodeScalarView()
        for _ in 0..<int(0...8) { text.append(scalar()) }
        return String(text)
    }

    mutating func digits(_ count: Int, leadingNonzero: Bool = false) -> String {
        var text = ""
        for position in 0..<count {
            let low = (position == 0 && leadingNonzero) ? 1 : 0
            text += String(int(low...9))
        }
        return text
    }

    mutating func number() -> JSONNumber {
        switch int(0...6) {
        case 0:
            return JSONNumber(Int.random(in: .min ... .max, using: &random))
        case 1:
            return JSONNumber(UInt64.random(in: .min ... .max, using: &random))
        case 2:
            return JSONNumber(int(-1000...1000))
        case 3:
            while true {
                let value = Double(bitPattern: UInt64.random(in: .min ... .max, using: &random))
                if let number = JSONNumber(value) { return number }
            }
        case 4:
            // A decimal with a fraction and an exponent, in the written form.
            let sign = chance(30) ? "-" : ""
            let whole = chance(30) ? "0" : digits(int(1...12), leadingNonzero: true)
            let fraction = chance(70) ? "." + digits(int(1...15)) : ""
            let exponent = chance(60) ? (chance(50) ? "e" : "E") + (chance(50) ? "+" : chance(50) ? "-" : "") + String(int(0...250)) : ""
            return JSONNumber(lexeme: sign + whole + fraction + exponent) ?? JSONNumber(0)
        case 5:
            // Integers wider than any machine type, still within Double's range.
            return JSONNumber(lexeme: (chance(30) ? "-" : "") + digits(int(19...40), leadingNonzero: true)) ?? JSONNumber(0)
        default:
            let zeros = ["0", "-0", "0.0", "-0.00", "0e0", "0E+5", "-0e-5"]
            return JSONNumber(lexeme: zeros[int(0...zeros.count - 1)]) ?? JSONNumber(0)
        }
    }

    mutating func value(depth: Int = 0) -> JSONValue {
        let containerOK = depth < 4
        switch int(0...(containerOK ? 7 : 4)) {
        case 0: return .null
        case 1: return .bool(chance(50))
        case 2, 3: return .number(number())
        case 4: return .string(string())
        case 5, 6:
            var elements: [JSONValue] = []
            for _ in 0..<int(0...5) { elements.append(value(depth: depth + 1)) }
            return .array(elements)
        default:
            var object = JSONObject()
            for _ in 0..<int(0...5) { object[string()] = value(depth: depth + 1) }
            return .object(object)
        }
    }
}

/// The same value with every object's members in a different order.
private func reordered(_ value: JSONValue, using random: inout SeededGenerator) -> JSONValue {
    switch value {
    case .array(let elements):
        return .array(elements.map { reordered($0, using: &random) })
    case .object(let object):
        var members = Array(object)
        members.shuffle(using: &random)
        return .object(JSONObject(members.map { JSONObject.Member(key: $0.key, value: reordered($0.value, using: &random)) }))
    default:
        return value
    }
}

private let allStyles: [JSONEncodingStyle] = [.canonical, .compact, .pretty(indent: 2), .pretty(indent: 0)]

@Suite("Properties")
struct PropertyTests {
    static let seeds: [UInt64] = Array(1...400)

    @Test("encode then parse gives an equal value, in every style", arguments: seeds)
    func roundTrip(_ seed: UInt64) throws {
        var generator = JSONGenerator(seed: seed)
        let value = generator.value()
        for style in allStyles {
            let bytes = value.encoded(style: style)
            let outcome = parse(bytes)
            let parsed = try #require(
                outcome.value, "seed \(seed), \(style): \(outcome.error.map(String.init(describing:)) ?? "")")
            #expect(parsed == value, "seed \(seed), \(style)")
            #expect(parsed.hashValue == value.hashValue, "seed \(seed), \(style)")
        }
    }

    @Test("canonical encoding is a fixed point", arguments: seeds)
    func canonicalFixedPoint(_ seed: UInt64) throws {
        var generator = JSONGenerator(seed: seed)
        let value = generator.value()
        let once = value.encoded(style: .canonical)
        let reparsed = try #require(parse(once).value, "seed \(seed)")
        #expect(reparsed.encoded(style: .canonical) == once, "seed \(seed)")
    }

    @Test("compact and pretty keep spelling and order, so they are fixed points too", arguments: seeds)
    func faithfulStylesAreFixedPoints(_ seed: UInt64) throws {
        var generator = JSONGenerator(seed: seed)
        let value = generator.value()
        for style in [JSONEncodingStyle.compact, .pretty(indent: 3)] {
            let once = value.encoded(style: style)
            let reparsed = try #require(parse(once).value, "seed \(seed)")
            #expect(reparsed.encoded(style: style) == once, "seed \(seed), \(style)")
        }
    }

    @Test("bytes mutated at random never crash the parser, and what it accepts round trips")
    func mutatedInputIsRefusedOrRoundTrips() throws {
        let seeds: [String] = [
            #"{"a":[1,2.5e3,-0,"xé😀"],"b":{"c":null,"d":true}}"#,
            #"[0.1,1e308,5e-324,-1.7976931348623157e308,9007199254740993]"#,
            #"{"k\n":"\"\\\/\b\f\n\r\t","":{},"é":[[]]}"#,
            "  [ \"a\" , { \"b\" : [ 1 , 2 ] } ] // c\n",
        ]
        let alphabet = Array(#"{}[]:,"\-+.eE0123456789tfnul /*"#.utf8) + [0x0A, 0x00, 0x1F, 0x7F, 0x80, 0xBF, 0xC0, 0xED, 0xF4, 0xF5, 0xFF]
        var random = SeededGenerator(seed: 0x5EED)
        var accepted = 0
        for iteration in 0..<20_000 {
            var bytes = Array(seeds[iteration % seeds.count].utf8)
            for _ in 0..<Int.random(in: 1...4, using: &random) where !bytes.isEmpty {
                let at = Int.random(in: 0..<bytes.count, using: &random)
                let byte = alphabet[Int.random(in: 0..<alphabet.count, using: &random)]
                switch Int.random(in: 0..<3, using: &random) {
                case 0: bytes[at] = byte
                case 1: bytes.insert(byte, at: at)
                default: bytes.remove(at: at)
                }
            }
            for options in [JSONParseOptions.strict, .jsonc] {
                guard let value = parse(bytes, options).value else { continue }
                accepted += 1
                for style in allStyles {
                    #expect(parse(value.encoded(style: style)).value == value, "\(String(decoding: bytes, as: UTF8.self))")
                }
            }
        }
        #expect(accepted > 100)
    }

    @Test("canonical bytes do not depend on member order", arguments: seeds)
    func canonicalIgnoresOrder(_ seed: UInt64) {
        var generator = JSONGenerator(seed: seed)
        let value = generator.value()
        var shuffler = SeededGenerator(seed: seed &* 31 &+ 7)
        let shuffled = reordered(value, using: &shuffler)
        #expect(shuffled == value, "seed \(seed)")
        #expect(shuffled.hashValue == value.hashValue, "seed \(seed)")
        #expect(shuffled.encoded(style: .canonical) == value.encoded(style: .canonical), "seed \(seed)")
    }

    @Test("canonical object keys are in UTF-16 order", arguments: seeds)
    func canonicalKeyOrder(_ seed: UInt64) throws {
        var generator = JSONGenerator(seed: seed)
        let value = generator.value()
        // Parsing keeps source order, so the reparsed keys show the order written.
        let reparsed = try #require(parse(value.encoded(style: .canonical)).value)
        func assertSorted(_ value: JSONValue) {
            switch value {
            case .array(let elements):
                for element in elements { assertSorted(element) }
            case .object(let object):
                let keys = object.keyList
                let sorted = keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
                #expect(keys == sorted, "seed \(seed)")
                for member in object { assertSorted(member.value) }
            default:
                break
            }
        }
        assertSorted(reparsed)
    }

    @Test("every value and key of a parsed document has a range that reparses to it", arguments: seeds)
    func documentRanges(_ seed: UInt64) throws {
        var generator = JSONGenerator(seed: seed)
        let value = generator.value()
        for style in [JSONEncodingStyle.compact, .pretty(indent: 2)] {
            let document = try JSONDocument(parsing: value.encoded(style: style))
            func walk(_ value: JSONValue, _ path: JSONPath, key: String?) throws {
                let range = try #require(document.range(of: path), "seed \(seed) \(path)")
                let text = try #require(document.text(in: range), "seed \(seed) \(path)")
                let sub = try #require(parse(text).value, "seed \(seed) \(path)")
                #expect(sub == value, "seed \(seed) \(path)")
                if let key {
                    let keyRange = try #require(document.keyRange(of: path), "seed \(seed) \(path)")
                    let keyText = try #require(document.text(in: keyRange))
                    #expect(parse(keyText).value == .string(key), "seed \(seed) \(path)")
                } else {
                    #expect(document.keyRange(of: path) == nil)
                }
                switch value {
                case .array(let elements):
                    for (index, element) in elements.enumerated() {
                        try walk(element, path.appending(index: index), key: nil)
                    }
                case .object(let object):
                    for member in object { try walk(member.value, path.appending(key: member.key), key: member.key) }
                default:
                    break
                }
            }
            try walk(value, .root, key: nil)
        }
    }

    @Test("random byte mutations never crash and keep diagnostics sane", arguments: seeds)
    func mutationFuzz(_ seed: UInt64) {
        var generator = JSONGenerator(seed: seed)
        let value = generator.value()
        var random = SeededGenerator(seed: seed &+ 0xF00D)
        for style in [JSONEncodingStyle.compact, .pretty(indent: 2)] {
            let original = value.encoded(style: style)
            for _ in 0..<8 {
                var bytes = original
                for _ in 0..<Int.random(in: 1...3, using: &random) where !bytes.isEmpty {
                    let position = Int.random(in: 0..<bytes.count, using: &random)
                    switch Int.random(in: 0...4, using: &random) {
                    case 0: bytes[position] = UInt8.random(in: .min ... .max, using: &random)
                    case 1: bytes.remove(at: position)
                    case 2: bytes.insert(UInt8.random(in: .min ... .max, using: &random), at: position)
                    case 3: bytes.removeSubrange(position...)
                    default: bytes.insert(contentsOf: bytes[position...].prefix(4), at: position)
                    }
                }
                for options in [JSONParseOptions.strict, .jsonc, JSONParseOptions(duplicateKeys: .lastWins)] {
                    switch parse(bytes, options) {
                    case .value(let parsed):
                        // Whatever is accepted must be stable under canonical re-encoding.
                        let canonical = parsed.encoded(style: .canonical)
                        #expect(parse(canonical).value == parsed, "seed \(seed)")
                    case .failure(let error):
                        #expect(error.location.offset >= 0 && error.location.offset <= bytes.count, "seed \(seed)")
                        #expect(error.location.line >= 1 && error.location.column >= 1, "seed \(seed)")
                        #expect(error.path.count <= options.maxDepth + 1, "seed \(seed)")
                        #expect(!error.message.isEmpty)
                    }
                }
            }
        }
    }

    @Test("arbitrary bytes never crash the parser") func arbitraryBytes() {
        var random = SeededGenerator(seed: 0xBAD_B17E)
        for _ in 0..<3000 {
            let length = Int.random(in: 0...40, using: &random)
            // Weighted toward JSON's own alphabet so the parser gets past its first byte.
            let alphabet = Array("{}[]\",:-+.eE0123456789tfnrueals \n\t/*\\u".utf8) + [0x00, 0x7F, 0x80, 0xC3, 0xE2, 0xED, 0xF0, 0xFF]
            let bytes = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &random)] }
            for options in [JSONParseOptions.strict, .jsonc] {
                if let parsed = parse(bytes, options).value {
                    #expect(parse(parsed.encoded()).value == parsed)
                }
            }
        }
    }
}
