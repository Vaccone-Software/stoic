import Foundation
import StoicJSON
import StoicSchema
import StoicTesting
import Testing

/// A price list: amounts as numbers, one as text too, one bounded.
struct Prices: Sendable, Equatable {
    var total = Decimal(0)
    var tax = Decimal(0)
    var discount = Decimal(0)

    static let schema = Schema.object(Prices.self, default: Prices(), unknownKeys: .reject) {
        Field("total", \.total, .decimal(), doc: "The amount.")
        Field("tax", \.tax, .decimal(acceptingStrings: true), doc: "Sent as a number or as text.")
        Field("discount", \.discount, .decimal(.range(0...100)), doc: "A percentage.")
    }
}

private func decimal(_ text: String) -> Decimal? {
    Schema<Decimal>.decimal().decodeReporting(text).value
}

@Suite("Decimals")
struct DecimalSchemaTests {
    @Test func digitsAreKeptThatADoubleCouldNotHold() throws {
        // 0.1 + 0.2 style traps: these numbers have no exact Double.
        #expect(decimal("0.1") == Decimal(string: "0.1"))
        #expect(decimal("19.99") == Decimal(string: "19.99"))
        #expect(decimal("12345678901234567890.123456789") == Decimal(string: "12345678901234567890.123456789"))
        #expect(decimal("-0.000000000000000000000000000000000001") == Decimal(string: "-0.000000000000000000000000000000000001"))
        let big = "99999999999999999999999999999999999999"
        let value = try #require(decimal(big))
        #expect("\(value)" == big)
        // The text is what was sent, so the digits survive a round trip.
        #expect(Schema<Decimal>.decimal().encode(value) == JSONValue.number(try #require(JSONNumber(lexeme: big))))
    }

    @Test func everySpellingOfANumberIsRead() {
        #expect(decimal("1e3") == Decimal(1000))
        #expect(decimal("1.5E+2") == Decimal(150))
        #expect(decimal("125e-2") == Decimal(string: "1.25"))
        #expect(decimal("-0") == Decimal(0))
        #expect(decimal("1.50") == Decimal(string: "1.5"))
    }

    @Test func writtenAsANumber() {
        let schema = Schema<Decimal>.decimal()
        #expect(schema.encode(Decimal(string: "19.99")!) == JSONValue.number(JSONNumber(lexeme: "19.99")!))
        #expect(schema.encode(Decimal(1000)) == JSONValue.number(JSONNumber(lexeme: "1000")!))
        #expect(schema.encode(Decimal(string: "-0.5")!).encodedString(style: .compact) == "-0.5")
        #expect(Prices.schema.encode(Prices(total: 5, tax: Decimal(string: "0.25")!, discount: 10)).encodedString(style: .compact)
            == #"{"total":5,"tax":0.25,"discount":10}"#)
    }

    @Test func aStringIsATypeMismatchUnlessAsked() {
        let result = Schema<Decimal>.decimal().decode(.string("12.50"))
        #expect(result.issues.map(\.code) == [.typeMismatch])
        #expect(result.issues.first?.suggestions == ["12.50"])
        #expect(Schema<Decimal>.decimal().decode(.bool(true)).issues.map(\.code) == [.typeMismatch])
        #expect(Schema<Decimal>.decimal().decode(.null).issues.map(\.code) == [.typeMismatch])
    }

    @Test func aStringIsReadWhenAsked() {
        let schema = Schema<Decimal>.decimal(acceptingStrings: true)
        #expect(schema.decode(.string("12.50")).value == Decimal(string: "12.5"))
        #expect(schema.decode(.string("-1e2")).value == Decimal(-100))
        #expect(schema.decode(12.5).value == Decimal(string: "12.5"))
        // Still written as a number.
        #expect(schema.encode(Decimal(string: "12.5")!) == JSONValue.number(JSONNumber(lexeme: "12.5")!))
        #expect(schema.decode(.bool(true)).issues.map(\.code) == [.typeMismatch])
    }

    @Test(.failureMode("design/06", "a decimal is not a number"))
    func textThatIsNotANumberSaysWhy() {
        let schema = Schema<Decimal>.decimal(acceptingStrings: true)
        let cases: [(String, String, [String])] = [
            ("1,5", "it uses a comma, which is not a decimal point", ["1.5"]),
            ("1,234.50", "it has a thousands separator", []),
            ("", "it is empty", []),
            (" 1", "it has whitespace around the number", ["1"]),
            ("+1", "it starts with `+`, which JSON numbers do not", ["1"]),
            (".5", "it has no digit before the decimal point", ["0.5"]),
            ("5.", "it has no digit after the decimal point", ["5"]),
            ("NaN", "it is not a number", []),
            ("12abc", "it is not a number", []),
        ]
        for (text, reason, suggestions) in cases {
            let result = schema.decode(.string(text))
            #expect(result.issues.map(\.code) == [.invalidFormat], "\(text)")
            #expect(result.issues.first?.parameters["message"]?.string == reason, "\(text)")
            #expect(result.issues.first?.suggestions == suggestions, "\(text)")
            #expect(result.issues.first?.parameters["format"]?.string == "decimal", "\(text)")
        }
    }

    @Test func moreDigitsThanADecimalHoldsIsRefusedNotRounded() {
        for text in ["1.00000000000000000000000000000000000001", "123456789012345678901234567890123456789", "1e200", "1e-200"] {
            let result = Schema<Decimal>.decimal().decode(.number(JSONNumber(lexeme: text)!))
            #expect(result.value == nil, "\(text)")
            #expect(result.issues.map(\.code) == [.outOfRange], "\(text)")
        }
        // Trailing zeros are not digits.
        #expect(decimal("1.000000000000000000000000000000000000000") == Decimal(1))
    }

    @Test func constraintsAreCheckedOnTheNumber() {
        let schema = Schema<Decimal>.decimal(.range(0...100), .multipleOf(0.05), acceptingStrings: true)
        #expect(schema.decode(.string("99.95")).value == Decimal(string: "99.95"))
        #expect(schema.decode(0.15).value == Decimal(string: "0.15"))
        #expect(schema.decode(100.05).issues.map(\.code) == [.outOfRange])
        #expect(schema.decode(.string("-1")).issues.map(\.code) == [.outOfRange])
        #expect(schema.decode(0.17).issues.map(\.code) == [.notMultiple])
    }

    @Test func notANumberHasNoSpelling() {
        let schema = Schema<Decimal>.decimal()
        #expect(schema.validate(Decimal.nan).map(\.code) == [.outOfRange])
        #expect(schema.encode(Decimal.nan) == JSONValue.null)
    }

    @Test func everyIssueOfAnObjectIsReported() {
        let result = Prices.schema.decodeReporting(#"{"total": "5", "tax": "1,5", "discount": 101}"#)
        #expect(result.issues.locations == ["$.total type_mismatch", "$.tax invalid_format", "$.discount out_of_range"])
    }

    @Test func theExportSaysNumber() {
        let exported = Schema<Decimal>.decimal(.range(0...100)).jsonSchema().object
        #expect(exported?["type"] == "number")
        #expect(exported?["minimum"] == 0)
        #expect(exported?["format"] == "decimal")
        let text = Schema<Decimal>.decimal(acceptingStrings: true).jsonSchema().object
        #expect(text?["anyOf"]?.array?.count == 2)
        #expect(text?["anyOf"]?.array?[0].object?["type"] == "number")
        #expect(text?["anyOf"]?.array?[1].object?["type"] == "string")
    }

    @Test func theSuiteHolds() {
        let report = SchemaSuite(Prices.schema).report(seed: 3, cases: 150)
        #expect(report.isClean, "\(report)")
        #expect(report.skipped == 0)
    }

    @Test func theTypeIsSchematic() {
        #expect(Decimal.schema.jsonSchema() == Schema<Decimal>.decimal().jsonSchema())
        #expect([Decimal].schema.decode(.array([1.5, 2])).value == [Decimal(string: "1.5")!, 2])
    }

    @Test func anyDecimalSurvivesARoundTrip() {
        var random = SeededGenerator(seed: 9)
        let schema = Schema<Decimal>.decimal()
        for _ in 0..<2000 {
            let digits = (0..<Int.random(in: 1...38, using: &random)).map { _ in String(Int.random(in: 0...9, using: &random)) }
            let point = Int.random(in: 0...digits.count, using: &random)
            let text = (digits[..<point] + ["."] + digits[point...]).joined()
            guard let value = Decimal(string: text) else { continue }
            let written = schema.encode(value)
            #expect(schema.decode(written).value == value, "\(text) was written as \(written)")
        }
    }
}
