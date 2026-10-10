#if STOIC_MACROS
import SwiftSyntax

/// The compile-time arithmetic the macro does on constraints and defaults:
/// only on literals, because only a literal is a value the macro can see.
/// An argument that is anything else (a constant, a call) is passed through
/// to the library, which checks it when the schema is built, and is left
/// unchecked here.

/// The value of an integer or floating-point literal, with an optional
/// leading minus.
func number(of expression: ExprSyntax) -> Double? {
    if let literal = expression.as(IntegerLiteralExprSyntax.self) {
        let text = literal.literal.text.filter { $0 != "_" }
        if let value = Int(text) { return Double(value) }
        let lowered = text.lowercased()
        if lowered.hasPrefix("0x"), let value = Int(lowered.dropFirst(2), radix: 16) { return Double(value) }
        if lowered.hasPrefix("0b"), let value = Int(lowered.dropFirst(2), radix: 2) { return Double(value) }
        if lowered.hasPrefix("0o"), let value = Int(lowered.dropFirst(2), radix: 8) { return Double(value) }
        return nil
    }
    if let literal = expression.as(FloatLiteralExprSyntax.self) {
        return Double(literal.literal.text.filter { $0 != "_" })
    }
    if let prefix = expression.as(PrefixOperatorExprSyntax.self), let inner = number(of: prefix.expression) {
        if prefix.operator.text == "-" { return -inner }
        if prefix.operator.text == "+" { return inner }
    }
    if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
        return number(of: only.expression)
    }
    return nil
}

/// One end of a range.
struct Bound {
    var value: Double
    var isInclusive: Bool
}

/// A range written with `...` or `..<`, its ends where they are literals.
struct RangeLiteral {
    var lower: ExprSyntax?
    var upper: ExprSyntax?
    var isHalfOpen: Bool

    /// `true` if an end is written but is not a number the macro can read.
    var hasUnreadableEnd: Bool {
        (lower != nil && number(of: lower!) == nil) || (upper != nil && number(of: upper!) == nil)
    }

    var lowerBound: Bound? { lower.flatMap { number(of: $0) }.map { Bound(value: $0, isInclusive: true) } }
    var upperBound: Bound? { upper.flatMap { number(of: $0) }.map { Bound(value: $0, isInclusive: !isHalfOpen) } }
}

/// Reads `a...b`, `a..<b`, `a...`, `...b` and `..<b`.
func rangeLiteral(_ expression: ExprSyntax) -> RangeLiteral? {
    func operands(_ operatorText: String) -> Bool? {
        operatorText == "..." ? false : (operatorText == "..<" ? true : nil)
    }
    if let sequence = expression.as(SequenceExprSyntax.self) {
        let elements = Array(sequence.elements)
        guard elements.count == 3, let op = elements[1].as(BinaryOperatorExprSyntax.self),
            let halfOpen = operands(op.operator.text)
        else { return nil }
        return RangeLiteral(lower: elements[0], upper: elements[2], isHalfOpen: halfOpen)
    }
    if let infix = expression.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self),
        let halfOpen = operands(op.operator.text)
    {
        return RangeLiteral(lower: infix.leftOperand, upper: infix.rightOperand, isHalfOpen: halfOpen)
    }
    if let postfix = expression.as(PostfixOperatorExprSyntax.self), postfix.operator.text == "..." {
        return RangeLiteral(lower: postfix.expression, upper: nil, isHalfOpen: false)
    }
    if let prefix = expression.as(PrefixOperatorExprSyntax.self), let halfOpen = operands(prefix.operator.text) {
        return RangeLiteral(lower: nil, upper: prefix.expression, isHalfOpen: halfOpen)
    }
    return nil
}

/// The numbers a value may take, as far as the literals say.
struct Interval {
    var lower: Bound?
    var upper: Bound?

    /// Narrows by another interval.
    mutating func intersect(_ other: Interval) {
        if let bound = other.lower {
            if let current = lower {
                if bound.value > current.value || (bound.value == current.value && !bound.isInclusive) { lower = bound }
            } else {
                lower = bound
            }
        }
        if let bound = other.upper {
            if let current = upper {
                if bound.value < current.value || (bound.value == current.value && !bound.isInclusive) { upper = bound }
            } else {
                upper = bound
            }
        }
    }

    /// Whether no number is in it.
    var isEmpty: Bool {
        guard let lower, let upper else { return false }
        if lower.value > upper.value { return true }
        return lower.value == upper.value && !(lower.isInclusive && upper.isInclusive)
    }

    func contains(_ value: Double) -> Bool {
        if let lower, value < lower.value || (value == lower.value && !lower.isInclusive) { return false }
        if let upper, value > upper.value || (value == upper.value && !upper.isInclusive) { return false }
        return true
    }
}

/// The interval a numeric constraint states, as far as it is literal.
func interval(of marker: Marker) -> Interval? {
    guard let argument = marker.arguments.first else { return nil }
    switch marker.kind {
    case .range:
        guard let range = rangeLiteral(argument.expression), !range.hasUnreadableEnd else { return nil }
        return Interval(lower: range.lowerBound, upper: range.upperBound)
    case .greaterThan:
        return number(of: argument.expression).map { Interval(lower: Bound(value: $0, isInclusive: false)) }
    case .lessThan:
        return number(of: argument.expression).map { Interval(upper: Bound(value: $0, isInclusive: false)) }
    default:
        return nil
    }
}

/// The counts a `@Length` or `@Count` allows, as far as it is literal.
func counts(of marker: Marker) -> (lower: Int?, upper: Int?)? {
    guard let argument = marker.arguments.first, let range = rangeLiteral(argument.expression), !range.hasUnreadableEnd
    else { return nil }
    func whole(_ value: Double) -> Int { Int(exactly: value.rounded()) ?? (value > 0 ? Int.max : Int.min) }
    let lower = range.lowerBound.map { whole($0.value) }
    let upper = range.upperBound.map { $0.isInclusive ? whole($0.value) : whole($0.value) - 1 }
    return (lower, upper)
}

/// What `@Length` measures in: the `unit:` argument, if it is spelt out.
func lengthUnit(of marker: Marker) -> String {
    for argument in marker.arguments where argument.label?.text == "unit" {
        if let member = argument.expression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
    }
    return "characters"
}

/// `text` measured in `unit`, the way the library counts it.
func length(of text: String, unit: String) -> Int {
    switch unit {
    case "graphemes": text.count
    case "utf8Bytes": text.utf8.count
    default: text.unicodeScalars.count
    }
}
#endif
