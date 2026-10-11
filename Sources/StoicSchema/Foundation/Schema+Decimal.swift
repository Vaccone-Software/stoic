#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif
internal import StoicJSON

extension Schema where Value == Decimal {
    /// A `Decimal`, read from a JSON number with every digit it was written
    /// with.
    ///
    /// Money and measurements are decimal numbers, and a `Double` in the
    /// middle turns `19.99` into `19.989999999999998`. StoicJSON keeps the
    /// text of a number, so this schema reads the digits and builds the
    /// `Decimal` from them: no `Double` is involved, and `0.1` is exactly one
    /// tenth. It is written back as a number, with the digits `Decimal`
    /// prints (so `1.50` comes back as `1.5`: a `Decimal` has no more to
    /// say about trailing zeros than its value).
    ///
    /// A `Decimal` holds 38 significant digits and a power of ten from -128
    /// to 127. A number with more digits (not counting trailing zeros) or a
    /// larger exponent is `out_of_range`, never rounded to fit.
    ///
    /// **Strings.** Some APIs write amounts as text (`"19.99"`) to keep a
    /// JSON parser from turning them into doubles. `acceptingStrings: true`
    /// reads those too, under the same grammar as a number: no `+`, no
    /// leading or trailing space, no `.5`, no comma; each of those is
    /// `invalid_format` with the reason and the likely spelling. A string is
    /// still written as a number.
    ///
    /// The constraints (`.range`, `.greaterThan`, `.multipleOf`) are checked
    /// on the number's digits, as they are for any number, so
    /// `.multipleOf(0.05)` accepts `0.15`. The JSON Schema export states
    /// them for a number, and leaves them out of the alternative that is a
    /// string, which JSON Schema cannot constrain by value.
    public static func decimal(_ constraints: Constraint..., acceptingStrings: Bool = false) -> Schema<Decimal> {
        decimalSchema(constraints, acceptingStrings: acceptingStrings)
    }

    private static let decimalExpectation = "a decimal number of at most 38 digits"

    private static func decimalSchema(_ constraints: [Constraint], acceptingStrings: Bool) -> Schema<Decimal> {
        let describe = acceptingStrings ? "a decimal number, or text spelling one" : "a decimal number"
        let validated: @Sendable (JSONNumber, inout DecodeState) -> Decimal? = { number, state in
            guard let value = DecimalNumber.decimal(from: number) else {
                state.report(.outOfRange, expected: decimalExpectation, actual: number.lexeme)
                return nil
            }
            guard state.apply(constraints, to: .number(number)) else { return nil }
            return value
        }
        let decoder: @Sendable (JSONValue, inout DecodeState) -> Decimal? = { json, state in
            switch json {
            case .number(let number):
                return validated(number, &state)
            case .string(let text) where acceptingStrings:
                switch DecimalNumber.parse(text) {
                case .success(let number):
                    return validated(number, &state)
                case .failure(let failure):
                    var parameters: JSONObject = ["format": .string("decimal")]
                    if state.secretDepth == 0 { parameters["message"] = .string(failure.message ?? "") }
                    state.report(
                        .invalidFormat, parameters: parameters, expected: describe, actual: json.briefDescription,
                        suggestions: failure.suggestions)
                    return nil
                }
            default:
                var hints: [String] = []
                if case .string(let text) = json, JSONNumber(lexeme: text) != nil { hints = [text] }
                state.typeMismatch(expected: describe, found: json, hints: hints)
                return nil
            }
        }
        let encoder: @Sendable (Decimal, inout EncodeState) -> JSONValue? = { value, state in
            guard let number = DecimalNumber.number(from: value) else {
                state.unrepresentable(expected: decimalExpectation, actual: "\(value)")
                return .null
            }
            return .number(number)
        }

        // What the generator may draw: whichever of these the constraints
        // allow. A conversion is code, so the schema proves its examples by
        // reading them.
        var candidates: [JSONValue] = [
            "0", "1", "-1", "0.1", "-0.5", "19.99", "100", "1.50", "1e3", "1.5E-2", "123456789.123456789",
            "99999999999999999999999999999999999999", "-0.0000000000000000000000000000000000001",
        ].map { .number(JSONNumber(lexeme: $0) ?? JSONNumber(0)) }
        if acceptingStrings { candidates += ["0.25", "-12.5", "1e2"].map { .string($0) } }
        let examples = candidates.filter { candidate in
            var state = DecodeState(options: .strict)
            return decoder(candidate, &state) != nil && state.errorCount == 0
        }

        var counterexamples: [TransformNode.Counterexample] = [
            .init(.number(JSONNumber(lexeme: "1e200")!), code: .outOfRange),
            .init(.number(JSONNumber(lexeme: "1.00000000000000000000000000000000000001")!), code: .outOfRange),
        ]
        var keywords = JSONObject()
        let base: SchemaNode
        if acceptingStrings {
            counterexamples += ["1,5", "", " 1", "+1", ".5", "NaN", "twelve"].map {
                .init(.string($0), code: .invalidFormat)
            }
            // A number, or text that spells one. The base is "anything" and
            // the alternatives are keywords, because a node has one type.
            var exporter = JSONSchemaExporter()
            var number = exporter.export(.number(constraints: constraints), location: "$")
            number["format"] = "decimal"
            keywords["anyOf"] = .array([
                .object(number),
                .object(["type": "string", "pattern": .string(DecimalNumber.pattern)]),
            ])
            base = .json(constraints: [])
        } else {
            base = .number(constraints: constraints)
        }
        return Schema(
            node: .transformed(
                TransformNode(
                    base: base, name: "Decimal", description: describe, examples: examples,
                    format: acceptingStrings ? nil : "decimal", keywords: keywords,
                    counterexamples: counterexamples, readsNumberDigits: true)),
            decoder: decoder, encoder: encoder)
    }
}

extension Decimal: Schematic {
    /// A number, with every digit; see ``Schema/decimal(_:acceptingStrings:)``
    /// for one that also reads text.
    public static var schema: Schema<Decimal> { .decimal() }
}

/// Between JSON's numbers and `Decimal`, through digits.
enum DecimalNumber {
    /// A JSON number's grammar, as a pattern.
    static let pattern = #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#

    /// The `Decimal` with exactly the digits of `number`, or `nil` if it has
    /// more than 38 significant digits or its power of ten is out of range.
    static func decimal(from number: JSONNumber) -> Decimal? {
        guard let exact = ExactDecimal(number), let value = Decimal(string: number.lexeme),
            let back = Self.number(from: value), ExactDecimal(back) == exact
        else { return nil }
        return value
    }

    /// The number a `Decimal` is written as, or `nil` for NaN.
    static func number(from value: Decimal) -> JSONNumber? {
        JSONNumber(lexeme: value.description)
    }

    /// Text that spells a number, or why not.
    static func parse(_ text: String) -> Result<JSONNumber, FormatFailure> {
        if let number = JSONNumber(lexeme: text) { return .success(number) }
        func valid(_ candidate: String) -> [String] { JSONNumber(lexeme: candidate) == nil ? [] : [candidate] }
        if text.isEmpty { return .failure(FormatFailure("it is empty")) }
        let trimmed = text.trimmingWhitespace()
        if trimmed != text, !trimmed.isEmpty {
            return .failure(FormatFailure("it has whitespace around the number", suggestions: valid(trimmed)))
        }
        if text.hasPrefix("+") {
            return .failure(FormatFailure("it starts with `+`, which JSON numbers do not", suggestions: valid(String(text.dropFirst()))))
        }
        if text.hasPrefix(".") || text.hasPrefix("-.") {
            let fixed = text.hasPrefix(".") ? "0" + text : "-0" + text.dropFirst()
            return .failure(FormatFailure("it has no digit before the decimal point", suggestions: valid(fixed)))
        }
        if text.hasSuffix("."), text.dropLast().allSatisfy({ $0.isNumber || $0 == "-" }) {
            return .failure(FormatFailure("it has no digit after the decimal point", suggestions: valid(String(text.dropLast()))))
        }
        let commas = text.filter { $0 == "," }.count
        if commas > 0, text.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." || $0 == "-" }) {
            if commas == 1, !text.contains(".") {
                return .failure(
                    FormatFailure(
                        "it uses a comma, which is not a decimal point", suggestions: valid(text.replacing(",", with: "."))))
            }
            return .failure(FormatFailure("it has a thousands separator"))
        }
        return .failure(FormatFailure("it is not a number"))
    }
}

extension String {
    fileprivate func trimmingWhitespace() -> String {
        var scalars = Substring(self)
        while scalars.first?.isWhitespace == true { scalars = scalars.dropFirst() }
        while scalars.last?.isWhitespace == true { scalars = scalars.dropLast() }
        return String(scalars)
    }
}
