#if STOIC_MACROS
import SwiftSyntax

/// The attributes `@Schema` reads from the declarations inside a type.
///
/// They are real macros (they have to be, or the compiler would not accept
/// the attribute), but they expand to nothing: `@Schema` reads them from the
/// syntax of the members it is given. What each one means is decided here,
/// in one place, and so are its mistakes.
enum MarkerKind: String, CaseIterable {
    case key = "Key"
    case secret = "Secret"
    case unit = "Unit"
    case aliases = "Aliases"
    case deprecated = "Deprecated"
    case nullable = "Nullable"
    case ignored = "Ignored"
    case preserveUnknownKeys = "PreserveUnknownKeys"
    case range = "Range"
    case greaterThan = "GreaterThan"
    case lessThan = "LessThan"
    case multipleOf = "MultipleOf"
    case length = "Length"
    case pattern = "Pattern"
    case count = "Count"
    case unique = "Unique"

    /// The constraint kinds, which become `Constraint` values.
    var isConstraint: Bool {
        switch self {
        case .range, .greaterThan, .lessThan, .multipleOf, .length, .pattern, .count, .unique: true
        default: false
        }
    }

    /// A constraint about a number.
    var constrainsNumbers: Bool {
        switch self {
        case .range, .greaterThan, .lessThan, .multipleOf: true
        default: false
        }
    }

    /// A constraint about a string.
    var constrainsStrings: Bool {
        self == .length || self == .pattern
    }

    /// A constraint about a collection as a whole.
    var constrainsCollections: Bool {
        self == .count || self == .unique
    }

    var spelling: String { "@" + rawValue }
}

/// One marker attribute found on a declaration.
struct Marker {
    var kind: MarkerKind
    var node: AttributeSyntax

    var arguments: [LabeledExprSyntax] {
        guard case .argumentList(let list)? = node.arguments else { return [] }
        return Array(list)
    }

    /// The constraint this attribute stands for, as the code that builds it.
    var constraintCode: String {
        precondition(kind.isConstraint)
        let name = kind.rawValue.lowercasingFirst
        guard case .argumentList(let list)? = node.arguments, !list.isEmpty else {
            return "." + name
        }
        let text = list.map { argument in
            (argument.label.map { $0.text + ": " } ?? "") + argument.expression.trimmedDescription
        }.joined(separator: ", ")
        return ".\(name)(\(text))"
    }
}

/// The markers among `attributes`, in source order. An attribute of the same
/// name that is not ours (`@StoicMacros.Key`) is found too; one that is not
/// a marker is ignored.
func markers(in attributes: AttributeListSyntax) -> [Marker] {
    attributes.compactMap { element in
        guard case .attribute(let attribute) = element else { return nil }
        let name: String?
        if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
            name = identifier.name.text
        } else if let member = attribute.attributeName.as(MemberTypeSyntax.self) {
            name = member.name.text
        } else {
            name = nil
        }
        guard let name, let kind = MarkerKind(rawValue: name) else { return nil }
        return Marker(kind: kind, node: attribute)
    }
}

/// The value of a plain string literal, and the literal as it was written.
/// `nil` for anything else: an interpolation, a variable, a call.
func plainStringLiteral(_ expression: ExprSyntax) -> (value: String, source: String)? {
    guard let literal = expression.as(StringLiteralExprSyntax.self),
        literal.segments.allSatisfy({ $0.is(StringSegmentSyntax.self) })
    else { return nil }
    // The value, with the escapes the macro cares about read back.
    let raw = literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
    return (unescape(raw), expression.trimmedDescription)
}

private func unescape(_ raw: String) -> String {
    guard raw.contains("\\") else { return raw }
    var out = ""
    var iterator = raw.makeIterator()
    while let character = iterator.next() {
        guard character == "\\", let next = iterator.next() else {
            out.append(character)
            continue
        }
        switch next {
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "0": out.append("\0")
        default: out.append(next)
        }
    }
    return out
}
#endif
