#if STOIC_MACROS
import SwiftDiagnostics
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
    case unknownCase = "UnknownCase"
    case preserveUnknownKeys = "PreserveUnknownKeys"
    case dateFormat = "DateFormat"
    case urlFormat = "URLFormat"
    case dataFormat = "DataFormat"
    case range = "Range"
    case greaterThan = "GreaterThan"
    case lessThan = "LessThan"
    case multipleOf = "MultipleOf"
    case length = "Length"
    case pattern = "Pattern"
    case count = "Count"
    case unique = "Unique"
    /// Only ever written as `.finite` in a `@Refined`; there is no attribute.
    case finite = "Finite"

    /// The constraint kinds, which become `Constraint` values.
    var isConstraint: Bool {
        switch self {
        case .range, .greaterThan, .lessThan, .multipleOf, .length, .pattern, .count, .unique, .finite: true
        default: false
        }
    }

    /// How a Foundation leaf is spelt on the wire.
    var isFormat: Bool {
        switch self {
        case .dateFormat, .urlFormat, .dataFormat: true
        default: false
        }
    }

    /// The type a format is about, as a word in a message.
    var formatSubject: String {
        switch self {
        case .dateFormat: "Date"
        case .urlFormat: "URL"
        default: "Data"
        }
    }

    /// A constraint about a number.
    var constrainsNumbers: Bool {
        switch self {
        case .range, .greaterThan, .lessThan, .multipleOf, .finite: true
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

/// One constraint or marker, as written: an attribute on a declaration
/// (`@Range(1...5)`) or, for `@Refined`, a call (`.range(1...5)`). Both say
/// the same thing, so the same checks read both.
struct Marker {
    var kind: MarkerKind
    var node: Syntax
    var arguments: [LabeledExprSyntax]
    /// How it is spelt in a message: `@Range` or `.range`.
    var name: String

    /// The fix that takes the attribute away. (A constraint passed to
    /// `@Refined` sits among other arguments, and removing it would leave a
    /// stray comma, so it gets no fix.)
    var removalFixIts: [FixIt] {
        node.is(AttributeSyntax.self) ? [.removing(node, "remove \(name)")] : []
    }

    /// The constraint this attribute stands for, as the code that builds it.
    var constraintCode: String {
        precondition(kind.isConstraint)
        let method = kind.rawValue.lowercasingFirst
        guard !arguments.isEmpty else { return "." + method }
        let text = arguments.map { argument in
            (argument.label.map { $0.text + ": " } ?? "") + argument.expression.trimmedDescription
        }.joined(separator: ", ")
        return ".\(method)(\(text))"
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
        var arguments: [LabeledExprSyntax] = []
        if case .argumentList(let list)? = attribute.arguments { arguments = Array(list) }
        return Marker(kind: kind, node: Syntax(attribute), arguments: arguments, name: kind.spelling)
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
