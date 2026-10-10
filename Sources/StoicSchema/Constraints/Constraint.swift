public import StoicJSON

/// A rule a value must satisfy, as data.
///
/// This is the rule that makes the schema layer credible: **a constraint is
/// a value, never a closure.** A closure can be run and nothing else. A
/// value can be run by the decoder, written into a JSON Schema by the
/// exporter, turned into boundary-biased test inputs by a generator and
/// shown as a slider's range by a settings screen, and all four agree
/// because all four read the same data. The one exception is
/// ``custom(id:description:check:)``, which exists so that a rule nobody
/// foresaw can still be written, and which every consumer treats as opaque:
/// the exporter renders an annotation, the generator gives up on it.
///
/// A constraint applies to the JSON kind it is about and is silent about the
/// rest, the way JSON Schema's own keywords behave: `.range` says nothing
/// about a string, `.length` nothing about a number. That keeps one
/// interpretation for the decoder and the exporter, and it lets a constraint
/// list be attached to ``Schema/json(_:)`` or a refined type of any base.
///
/// Build constraints with the static functions, which accept ordinary Swift
/// ranges: `.range(200...4000)`, `.length(1...64)`, `.count(0...8)`.
public struct Constraint: Sendable, Hashable, CustomStringConvertible {
    /// What the constraint says. Exporters and generators switch over this;
    /// it is not frozen, so keep a `default` that treats a kind you do not
    /// know as opaque.
    public enum Kind: Sendable, Hashable {
        /// A number between bounds, each inclusive or exclusive.
        case range(NumberRange)
        /// A number that is a whole multiple of a positive step.
        case multipleOf(JSONNumber)
        /// A string of a given length, counted in an explicit unit.
        case length(CountRange, unit: LengthUnit)
        /// An array's element count, or an object's entry count.
        case count(CountRange)
        /// A string containing a match of a regular expression.
        case pattern(String)
        /// A value equal to one of a fixed set.
        case oneOf([JSONValue])
        /// An array whose elements are pairwise different.
        case unique
        /// A number a finite `Double` can hold.
        case finite
        /// A rule only code can state. See ``Custom``.
        case custom(Custom)
    }

    public var kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    // MARK: Numbers

    /// A number within `bounds`: `.range(200...4000)`, `.range(0.1...10)`,
    /// `.range(1...)`, `.range(..<100)`. Integer bounds are exact; a
    /// `Double` bound is the shortest decimal that reads back as it, so
    /// `.range(0.1...10)` admits `0.1`. An infinite bound is no bound.
    public static func range(_ bounds: some NumberBounds) -> Constraint {
        Constraint(.range(bounds.numberRange))
    }

    /// A number strictly above `bound`. `.greaterThan(0)` is a positive
    /// number, which no closed range can say.
    public static func greaterThan(_ bound: some NumericBound) -> Constraint {
        Constraint(.range(NumberRange(lower: bound.jsonNumber.map { NumberBound($0, isInclusive: false) })))
    }

    /// A number strictly below `bound`.
    public static func lessThan(_ bound: some NumericBound) -> Constraint {
        Constraint(.range(NumberRange(upper: bound.jsonNumber.map { NumberBound($0, isInclusive: false) })))
    }

    /// A number that is a whole multiple of `step`. A step of zero or less
    /// is a mistake in the schema and is reported as an
    /// ``IssueCode/invalidConstraint`` issue when checked.
    public static func multipleOf(_ step: some NumericBound) -> Constraint {
        guard let number = step.jsonNumber else { return Constraint(.multipleOf(JSONNumber(0))) }
        return Constraint(.multipleOf(number))
    }

    /// A number a finite `Double` can hold. `Schema.double` insists on this
    /// anyway; the constraint is for refined types over `Double`, whose
    /// Swift values can be NaN.
    public static var finite: Constraint { Constraint(.finite) }

    // MARK: Strings

    /// A string whose length, in `unit`, is within `bounds`.
    ///
    /// The default unit is ``LengthUnit/characters``: **Unicode scalars**,
    /// not Swift `Character`s. That is what JSON Schema's `minLength` and
    /// `maxLength` count, so the constraint and its export mean the same
    /// thing in every validator. It is also a trap if you expect `count`:
    /// an emoji with a skin tone is two scalars, `e` plus a combining acute
    /// is two. Ask for ``LengthUnit/graphemes`` to count what a reader sees
    /// and ``LengthUnit/utf8Bytes`` to count what a database column stores.
    public static func length(_ bounds: some CountBounds, unit: LengthUnit = .characters) -> Constraint {
        Constraint(.length(bounds.countRange, unit: unit))
    }

    /// A string matching `source`, a regular expression in Swift's `Regex`
    /// syntax, found anywhere in the string (anchor with `^` and `$` to
    /// match all of it), as in JSON Schema. Matching counts Unicode scalars,
    /// so `.` is one scalar.
    ///
    /// The source text is what is stored and exported, and the regex is
    /// compiled when a value is checked, so a schema stays `Sendable`.
    /// Swift's syntax is close to ECMA-262, which JSON Schema names, but not
    /// the same: keep patterns to character classes, groups, alternation and
    /// repetition and they mean the same in both. A pattern that is not a
    /// regular expression is an ``IssueCode/invalidConstraint`` issue.
    ///
    /// A backtracking matcher can take exponential time on a hostile string,
    /// so put a ``length(_:unit:)`` constraint before a pattern: when the
    /// length is wrong the pattern is not run.
    public static func pattern(_ source: String) -> Constraint {
        Constraint(.pattern(source))
    }

    // MARK: Collections

    /// A collection of `bounds` elements: an array's length, or the number
    /// of entries in an object or dictionary.
    public static func count(_ bounds: some CountBounds) -> Constraint {
        Constraint(.count(bounds.countRange))
    }

    /// An array whose elements are pairwise different, by JSON equality
    /// (`1` and `1.0` are the same, strings compare by scalars).
    public static var unique: Constraint { Constraint(.unique) }

    // MARK: Any value

    /// A value equal to one of `values`.
    public static func oneOf(_ values: [JSONValue]) -> Constraint {
        Constraint(.oneOf(values))
    }

    /// The escape hatch: a rule written as code.
    ///
    /// `id` names the rule for machines (it becomes a parameter of the
    /// issue and appears in the JSON Schema export), `description` says it
    /// for people (it is the issue's expectation), and `check` returns
    /// whether the value is acceptable. Anything the built-in constraints
    /// can say, say with them: a closure is invisible to the exporter, the
    /// generators and the UI, and two customs with the same `id` and
    /// `description` compare equal whatever their closures do.
    public static func custom(
        id: String,
        description: String,
        check: @escaping @Sendable (JSONValue) -> Bool
    ) -> Constraint {
        Constraint(.custom(Custom(id: id, description: description, check: check)))
    }

    // MARK: Description

    /// The rule in words, as the issue for a violation expects it: `a number
    /// between 200 and 4000`, `a string of 1 to 64 characters`.
    public var description: String {
        switch kind {
        case .range(let range): range.expectation
        case .multipleOf(let step): "a multiple of \(step.lexeme)"
        case .length(let range, let unit): "a string of " + range.phrase(noun: unit.noun)
        case .count(let range): "a collection of " + range.phrase(noun: "elements")
        case .pattern(let source): "a string matching /\(source)/"
        case .oneOf(let values): "one of " + Self.list(values)
        case .unique: "unique elements"
        case .finite: "a finite number"
        case .custom(let custom): custom.description
        }
    }

    private static func list(_ values: [JSONValue]) -> String {
        let shown = values.prefix(8).map { $0.encodedString(style: .compact) }
        return shown.joined(separator: ", ") + (values.count > 8 ? ", \u{2026}" : "")
    }
}

// MARK: - Payloads

/// How a string's length is counted. The unit is part of the constraint
/// because the three common answers differ, and a length limit that counts
/// one thing while its documentation says another is a bug nobody sees until
/// the first emoji.
public enum LengthUnit: Sendable, Hashable, CaseIterable {
    /// Unicode scalars (code points). The default: it is what JSON Schema
    /// counts, so it is the only unit the exporter writes as `minLength`
    /// and `maxLength`. Not Swift's `Character`; see ``graphemes``.
    case characters
    /// Extended grapheme clusters, Swift's `String.count`: what a reader
    /// sees as one letter. Exported as an `x-stoic-length` annotation.
    case graphemes
    /// UTF-8 bytes: what a database column or a wire protocol limits.
    /// Exported as an `x-stoic-length` annotation.
    case utf8Bytes

    var noun: String {
        switch self {
        case .characters: "characters"
        case .graphemes: "graphemes"
        case .utf8Bytes: "UTF-8 bytes"
        }
    }

    /// The name used in annotations and issue parameters.
    public var name: String {
        switch self {
        case .characters: "characters"
        case .graphemes: "graphemes"
        case .utf8Bytes: "utf8Bytes"
        }
    }
}

/// One end of a numeric range.
public struct NumberBound: Sendable, Hashable {
    public var value: JSONNumber
    /// Whether the bound itself is admitted (`<=`) or not (`<`).
    public var isInclusive: Bool

    public init(_ value: JSONNumber, isInclusive: Bool = true) {
        self.value = value
        self.isInclusive = isInclusive
    }
}

/// The bounds of a numeric constraint; a side that is `nil` is open.
public struct NumberRange: Sendable, Hashable {
    public var lower: NumberBound?
    public var upper: NumberBound?

    public init(lower: NumberBound? = nil, upper: NumberBound? = nil) {
        self.lower = lower
        self.upper = upper
    }

    /// Whether `number` is within the range.
    public func contains(_ number: JSONNumber) -> Bool {
        if let lower {
            let order = number.compared(to: lower.value)
            if order < 0 || (order == 0 && !lower.isInclusive) { return false }
        }
        if let upper {
            let order = number.compared(to: upper.value)
            if order > 0 || (order == 0 && !upper.isInclusive) { return false }
        }
        return true
    }

    /// `a number between 200 and 4000`, `a number that is greater than 0`.
    var expectation: String {
        if let lower, let upper, lower.isInclusive, upper.isInclusive {
            return "a number between \(lower.value.lexeme) and \(upper.value.lexeme)"
        }
        var parts: [String] = []
        if let lower {
            parts.append((lower.isInclusive ? "at least " : "greater than ") + lower.value.lexeme)
        }
        if let upper {
            parts.append((upper.isInclusive ? "at most " : "less than ") + upper.value.lexeme)
        }
        return parts.isEmpty ? "any number" : "a number that is " + parts.joined(separator: " and ")
    }
}

/// Inclusive bounds on a count; a side that is `nil` is open.
public struct CountRange: Sendable, Hashable {
    public var lower: Int?
    public var upper: Int?

    public init(lower: Int? = nil, upper: Int? = nil) {
        self.lower = lower
        self.upper = upper
    }

    public func contains(_ count: Int) -> Bool {
        (lower.map { count >= $0 } ?? true) && (upper.map { count <= $0 } ?? true)
    }

    /// `1 to 64 characters`, `at least 1 character`, `exactly 8 elements`.
    /// `singular` defaults to the plural without its `s`.
    func phrase(noun: String, singular: String? = nil) -> String {
        let one = singular ?? (noun.hasSuffix("s") ? String(noun.dropLast()) : noun)
        func counted(_ n: Int) -> String {
            "\(n) \(n == 1 ? one : noun)"
        }
        switch (lower, upper) {
        case (let low?, let high?) where low == high: return "exactly " + counted(low)
        case (let low?, let high?): return "\(low) to " + counted(high)
        case (let low?, nil): return "at least " + counted(low)
        case (nil, let high?): return "at most " + counted(high)
        case (nil, nil): return "any number of \(noun)"
        }
    }
}

/// A rule written as code; see ``Constraint/custom(id:description:check:)``.
///
/// Equality and hashing look at `id` and `description` only. Closures cannot
/// be compared, and a schema whose constraints are compared (in a test, or by
/// a migration checker) means "the same rule", which is what the id names.
public struct Custom: Sendable, Hashable {
    public var id: String
    public var description: String
    public var check: @Sendable (JSONValue) -> Bool

    public init(id: String, description: String, check: @escaping @Sendable (JSONValue) -> Bool) {
        self.id = id
        self.description = description
        self.check = check
    }

    public static func == (lhs: Custom, rhs: Custom) -> Bool {
        lhs.id == rhs.id && lhs.description == rhs.description
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(description)
    }
}

// MARK: - Range sugar

/// A number that can be a bound of a ``Constraint``.
public protocol NumericBound: Sendable {
    /// The bound as a JSON number, or `nil` for an infinite bound, which
    /// means "no bound on this side".
    var jsonNumber: JSONNumber? { get }
}

extension Int: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension Int8: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension Int16: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension Int32: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension Int64: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension UInt: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension UInt8: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension UInt16: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension UInt32: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension UInt64: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }
extension Double: NumericBound { public var jsonNumber: JSONNumber? { JSONNumber(self) } }

/// A Swift range of numbers that ``Constraint/range(_:)`` accepts: closed,
/// half-open and one-sided ranges of integers and doubles.
public protocol NumberBounds {
    var numberRange: NumberRange { get }
}

extension ClosedRange: NumberBounds where Bound: NumericBound {
    public var numberRange: NumberRange {
        NumberRange(
            lower: lowerBound.jsonNumber.map { NumberBound($0) },
            upper: upperBound.jsonNumber.map { NumberBound($0) })
    }
}

extension Range: NumberBounds where Bound: NumericBound {
    public var numberRange: NumberRange {
        NumberRange(
            lower: lowerBound.jsonNumber.map { NumberBound($0) },
            upper: upperBound.jsonNumber.map { NumberBound($0, isInclusive: false) })
    }
}

extension PartialRangeFrom: NumberBounds where Bound: NumericBound {
    public var numberRange: NumberRange {
        NumberRange(lower: lowerBound.jsonNumber.map { NumberBound($0) })
    }
}

extension PartialRangeThrough: NumberBounds where Bound: NumericBound {
    public var numberRange: NumberRange {
        NumberRange(upper: upperBound.jsonNumber.map { NumberBound($0) })
    }
}

extension PartialRangeUpTo: NumberBounds where Bound: NumericBound {
    public var numberRange: NumberRange {
        NumberRange(upper: upperBound.jsonNumber.map { NumberBound($0, isInclusive: false) })
    }
}

/// A Swift range of `Int`s that ``Constraint/length(_:unit:)`` and
/// ``Constraint/count(_:)`` accept.
public protocol CountBounds {
    var countRange: CountRange { get }
}

extension ClosedRange: CountBounds where Bound == Int {
    public var countRange: CountRange { CountRange(lower: lowerBound, upper: upperBound) }
}

extension Range: CountBounds where Bound == Int {
    public var countRange: CountRange { CountRange(lower: lowerBound, upper: upperBound - 1) }
}

extension PartialRangeFrom: CountBounds where Bound == Int {
    public var countRange: CountRange { CountRange(lower: lowerBound) }
}

extension PartialRangeThrough: CountBounds where Bound == Int {
    public var countRange: CountRange { CountRange(upper: upperBound) }
}

extension PartialRangeUpTo: CountBounds where Bound == Int {
    public var countRange: CountRange { CountRange(upper: upperBound - 1) }
}
