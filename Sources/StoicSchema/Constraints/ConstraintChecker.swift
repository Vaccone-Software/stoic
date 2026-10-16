public import StoicJSON

/// One way a value failed a constraint, before it is given a path and a
/// severity and becomes an ``Issue``.
struct Violation {
    var code: IssueCode
    /// Where, relative to the value that was checked: empty for the value
    /// itself, `[index]` for the duplicate element a `unique` found.
    var relativePath: JSONPath = JSONPath()
    var parameters: JSONObject = JSONObject()
    var expected: String
    /// The offending value as JSON text, or `nil` when it adds nothing.
    var actual: String?
}

/// Runs constraints against JSON values: the single interpreter that the
/// decoder, the refined types and the public ``Constraint/check(_:at:)``
/// all share, so the rule that admits a value is the rule that is exported.
///
/// A checker owns a cache of compiled regular expressions, because a
/// `Regex` is not `Sendable` and so cannot live in the (sendable) schema;
/// each decode makes one checker and compiles each pattern once however many
/// strings it checks.
struct ConstraintChecker {
    private var regexes: [String: Regex<AnyRegexOutput>?] = [:]

    init() {}

    /// Every violation of `constraints` by `value`, in constraint order.
    /// A pattern is not run on a string whose length already failed: the
    /// length check is cheap and the match may not be.
    mutating func violations(of constraints: [Constraint], in value: JSONValue) -> [Violation] {
        var found: [Violation] = []
        var lengthFailed = false
        for constraint in constraints {
            let new = violations(of: constraint, in: value, skippingPattern: lengthFailed)
            if case .length = constraint.kind, !new.isEmpty { lengthFailed = true }
            found.append(contentsOf: new)
        }
        return found
    }

    private mutating func violations(
        of constraint: Constraint,
        in value: JSONValue,
        skippingPattern: Bool
    ) -> [Violation] {
        let expected = constraint.description
        switch (constraint.kind, value) {
        case (.range(let range), .number(let number)):
            guard !range.contains(number) else { return [] }
            return [
                Violation(
                    code: .outOfRange, parameters: Self.parameters(of: range), expected: expected,
                    actual: number.lexeme)
            ]

        case (.multipleOf(let step), .number(let number)):
            guard step > JSONNumber(0) else {
                return [Self.invalid("multipleOf needs a step greater than zero, not \(step.lexeme)")]
            }
            guard !number.isMultiple(of: step) else { return [] }
            return [
                Violation(
                    code: .notMultiple, parameters: ["step": .number(step)], expected: expected,
                    actual: number.lexeme)
            ]

        case (.finite, .number(let number)):
            guard number.double == nil else { return [] }
            return [Violation(code: .notFinite, expected: expected, actual: number.lexeme)]

        case (.length(let range, let unit), .string(let string)):
            let length: Int
            switch unit {
            case .characters: length = string.unicodeScalars.count
            case .graphemes: length = string.count
            case .utf8Bytes: length = string.utf8.count
            }
            guard !range.contains(length) else { return [] }
            let tooShort = range.lower.map { length < $0 } ?? false
            var parameters: JSONObject = ["count": .number(JSONNumber(length)), "unit": .string(unit.noun)]
            Self.add(range, to: &parameters)
            return [Violation(code: tooShort ? .tooShort : .tooLong, parameters: parameters, expected: expected)]

        case (.count(let range), .array(let elements)):
            return Self.countViolation(range, count: elements.count, noun: "elements", singular: "element")

        case (.count(let range), .object(let object)):
            return Self.countViolation(range, count: object.count, noun: "entries", singular: "entry")

        case (.pattern(let source), .string(let string)):
            if skippingPattern { return [] }
            guard let regex = compiled(source) else {
                return [Self.invalid("`\(source)` is not a regular expression")]
            }
            let matches = string.firstMatch(of: regex) != nil
            guard !matches else { return [] }
            return [
                Violation(
                    code: .patternMismatch, parameters: ["pattern": .string(source)], expected: expected,
                    actual: value.briefDescription)
            ]

        case (.oneOf(let allowed), _):
            guard !allowed.contains(value) else { return [] }
            return [Violation(code: .notOneOf, expected: expected, actual: value.briefDescription)]

        case (.unique, .array(let elements)):
            var first: [JSONValue: Int] = [:]
            var found: [Violation] = []
            for (index, element) in elements.enumerated() {
                if let earlier = first[element] {
                    found.append(
                        Violation(
                            code: .notUnique, relativePath: JSONPath([.index(index)]),
                            parameters: ["firstIndex": .number(JSONNumber(earlier))],
                            expected: expected, actual: element.briefDescription))
                } else {
                    first[element] = index
                }
            }
            return found

        case (.custom(let custom), _):
            guard !custom.check(value) else { return [] }
            return [
                Violation(
                    code: .custom,
                    parameters: ["id": .string(custom.id), "description": .string(custom.description)],
                    expected: expected, actual: value.briefDescription)
            ]

        default:
            // A rule about another kind of value says nothing here.
            return []
        }
    }

    private mutating func compiled(_ source: String) -> Regex<AnyRegexOutput>? {
        if let cached = regexes[source] { return cached }
        let regex = (try? Regex(source))?.matchingSemantics(.unicodeScalar)
        regexes[source] = .some(regex)
        return regex
    }

    private static func invalid(_ message: String) -> Violation {
        Violation(
            code: .invalidConstraint, parameters: ["message": .string(message)],
            expected: "a valid constraint")
    }

    private static func countViolation(_ range: CountRange, count: Int, noun: String, singular: String) -> [Violation] {
        guard !range.contains(count) else { return [] }
        let tooFew = range.lower.map { count < $0 } ?? false
        var parameters: JSONObject = ["count": .number(JSONNumber(count))]
        add(range, to: &parameters)
        let expectation = "a collection of " + range.phrase(noun: noun, singular: singular)
        return [Violation(code: tooFew ? .tooFew : .tooMany, parameters: parameters, expected: expectation)]
    }

    private static func add(_ range: CountRange, to parameters: inout JSONObject) {
        if let lower = range.lower { parameters["minimum"] = .number(JSONNumber(lower)) }
        if let upper = range.upper { parameters["maximum"] = .number(JSONNumber(upper)) }
    }

    private static func parameters(of range: NumberRange) -> JSONObject {
        var parameters = JSONObject()
        if let lower = range.lower {
            parameters[lower.isInclusive ? "minimum" : "exclusiveMinimum"] = .number(lower.value)
        }
        if let upper = range.upper {
            parameters[upper.isInclusive ? "maximum" : "exclusiveMaximum"] = .number(upper.value)
        }
        return parameters
    }
}

extension JSONValue {
    /// The value as short JSON text for a message: scalars in full (strings
    /// cut at 48 scalars), containers by size, so describing a hostile
    /// megabyte value costs next to nothing.
    var briefDescription: String {
        switch self {
        case .null, .bool, .number:
            return encodedString(style: .compact)
        case .string(let string):
            let limit = 48
            guard string.unicodeScalars.count > limit else { return encodedString(style: .compact) }
            var cut = String.UnicodeScalarView()
            cut.append(contentsOf: string.unicodeScalars.prefix(limit))
            let quoted = JSONValue.string(String(cut)).encodedString(style: .compact)
            return String(quoted.dropLast()) + "\u{2026}\""
        case .array(let elements):
            return "an array of \(elements.count) element\(elements.count == 1 ? "" : "s")"
        case .object(let object):
            return "an object with \(object.count) entr\(object.count == 1 ? "y" : "ies")"
        }
    }
}

// MARK: - Public interpretation

extension Constraint {
    /// The issues `value` raises against this constraint, with `path` as
    /// their location. Empty when the value satisfies it.
    ///
    /// This is the interpreter the decoder uses, exposed so a constraint
    /// can be tested on its own and so code that holds JSON outside a
    /// schema (a migration step, a form) applies the same rule.
    public func check(_ value: JSONValue, at path: JSONPath = .root) -> [Issue] {
        [self].check(value, at: path)
    }
}

extension Array where Element == Constraint {
    /// The issues `value` raises against these constraints, in order.
    public func check(_ value: JSONValue, at path: JSONPath = .root) -> [Issue] {
        var checker = ConstraintChecker()
        return checker.violations(of: self, in: value).map { violation in
            Issue(
                path: JSONPath(path.components + violation.relativePath.components),
                code: violation.code, parameters: violation.parameters,
                expected: violation.expected, actual: violation.actual)
        }
    }
}
