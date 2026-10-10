#if STOIC_MACROS
import SwiftSyntax

/// What the macro can tell about a property's type from how it is spelt.
///
/// The macro sees syntax, not types: `Port` might be a typealias of `Int` or a
/// refined type or a struct, and the macro cannot know which. So it knows the
/// standard library's spellings, and for any other name it emits `Name.schema`
/// and lets the compiler say whether that exists. Types it knows cannot have
/// a schema (a `Date`, a `Set`) it refuses by name, with the reason.
indirect enum ValueType {
    case bool
    case double
    case string
    case json
    /// Any fixed-width integer, by name.
    case integer(String)
    case array(ValueType)
    case dictionary(ValueType)
    case optional(ValueType)
    /// `Secret<Wrapped>`.
    case secret(ValueType)
    /// Any other name, as written, and whether it names the type being
    /// declared (so its schema must be reached lazily).
    case named(String, isSelf: Bool)

    /// The fixed-width integers other than `Int`, `Int64` and `UInt64`,
    /// which have schemas of their own.
    static let otherIntegers: Set<String> = ["Int8", "Int16", "Int32", "UInt", "UInt8", "UInt16", "UInt32"]

    /// What a constraint on the value ends up applying to.
    enum Leaf {
        case number, string, bool, json, named
    }

    /// The innermost value: what `@Range` and `@Length` talk about, through
    /// optionals, arrays, dictionaries and secrets.
    var leaf: Leaf {
        switch self {
        case .bool: .bool
        case .double, .integer: .number
        case .string: .string
        case .json: .json
        case .array(let element), .dictionary(let element), .optional(let element), .secret(let element): element.leaf
        case .named: .named
        }
    }

    /// The array or dictionary that `@Count` and `@Unique` talk about: the
    /// outermost one, looking through optionals and secrets.
    var collection: ValueType? {
        switch self {
        case .array, .dictionary: self
        case .optional(let wrapped), .secret(let wrapped): wrapped.collection
        default: nil
        }
    }

    var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    var isOptional: Bool {
        if case .optional = self { return true }
        return false
    }

    /// Whether a secret appears at the field's top, so the field is secret.
    var isSecret: Bool {
        switch self {
        case .secret: true
        case .optional(let wrapped): wrapped.isSecret
        default: false
        }
    }
}

/// Why a type cannot be a field, in words.
struct UnsupportedType: Error {
    var node: Syntax
    var reason: String
}

/// Types the standard library or Foundation has, that have no schema, and
/// what to use instead.
private let knownUnsupported: [String: String] = [
    "Float": "use `Double`",
    "Float16": "use `Double`",
    "CGFloat": "use `Double`",
    "Decimal": "use `String` with a `@Pattern`, or write a transform",
    "Date": "write a transform from a string or a number",
    "URL": "write a transform from a string",
    "UUID": "write a transform from a string",
    "Data": "write a transform from a string",
    "Character": "use `String` with `@Length(1...1)`",
    "Substring": "use `String`",
    "Set": "use an array with `@Unique`",
    "Any": "use `JSONValue` for a value of unknown shape",
    "AnyObject": "use `JSONValue` for a value of unknown shape",
]

/// Reads a type annotation.
///
/// - Parameter enclosing: the name of the type being declared.
func classify(_ type: TypeSyntax, enclosing: String) throws(UnsupportedType) -> ValueType {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return try classify(name: identifier.name.text, arguments: identifier.genericArgumentClause, whole: type, enclosing: enclosing)
    }
    if let member = type.as(MemberTypeSyntax.self) {
        // `Swift.String` is `String`; anything else qualified is a name to
        // be resolved by the compiler.
        if let base = member.baseType.as(IdentifierTypeSyntax.self), base.name.text == "Swift" {
            return try classify(name: member.name.text, arguments: member.genericArgumentClause, whole: type, enclosing: enclosing)
        }
        return .named(type.trimmedDescription, isSelf: type.trimmedDescription == enclosing)
    }
    if let array = type.as(ArrayTypeSyntax.self) {
        return .array(try classify(array.element, enclosing: enclosing))
    }
    if let dictionary = type.as(DictionaryTypeSyntax.self) {
        let key = dictionary.key.trimmedDescription
        guard key == "String" || key == "Swift.String" else {
            throw UnsupportedType(
                node: Syntax(dictionary.key),
                reason: "a dictionary needs `String` keys to be a JSON object, not `\(key)`; use an array of entries instead")
        }
        return .dictionary(try classify(dictionary.value, enclosing: enclosing))
    }
    if let optional = type.as(OptionalTypeSyntax.self) {
        return .optional(try classify(optional.wrappedType, enclosing: enclosing))
    }
    if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        throw UnsupportedType(
            node: Syntax(unwrapped),
            reason: "an implicitly unwrapped optional hides whether the key is required; write `\(unwrapped.wrappedType.trimmedDescription)?`")
    }
    if type.is(TupleTypeSyntax.self) {
        throw UnsupportedType(node: Syntax(type), reason: "a tuple has no JSON shape; declare a struct")
    }
    if type.is(FunctionTypeSyntax.self) {
        throw UnsupportedType(node: Syntax(type), reason: "a function cannot be read from JSON")
    }
    if type.is(SomeOrAnyTypeSyntax.self) {
        throw UnsupportedType(node: Syntax(type), reason: "an existential or opaque type has no single schema; use the concrete type")
    }
    if let attributed = type.as(AttributedTypeSyntax.self) {
        return try classify(attributed.baseType, enclosing: enclosing)
    }
    throw UnsupportedType(node: Syntax(type), reason: "the macro cannot read this type")
}

private func classify(
    name: String, arguments: GenericArgumentClauseSyntax?, whole: TypeSyntax, enclosing: String
) throws(UnsupportedType) -> ValueType {
    let generic = arguments?.arguments.compactMap { argument -> TypeSyntax? in
        if case .type(let type) = argument.argument { return type }
        return nil
    } ?? []
    switch name {
    case "Bool" where arguments == nil: return .bool
    case "Double" where arguments == nil: return .double
    case "String" where arguments == nil: return .string
    case "JSONValue" where arguments == nil: return .json
    case "Int", "Int64", "UInt64":
        if arguments == nil { return .integer(name) }
    case "Array":
        if generic.count == 1 { return .array(try classify(generic[0], enclosing: enclosing)) }
    case "Optional":
        if generic.count == 1 { return .optional(try classify(generic[0], enclosing: enclosing)) }
    case "Secret":
        if generic.count == 1 { return .secret(try classify(generic[0], enclosing: enclosing)) }
    case "Dictionary":
        if generic.count == 2 {
            guard generic[0].trimmedDescription == "String" else {
                throw UnsupportedType(
                    node: Syntax(generic[0]),
                    reason: "a dictionary needs `String` keys to be a JSON object, not `\(generic[0].trimmedDescription)`")
            }
            return .dictionary(try classify(generic[1], enclosing: enclosing))
        }
    default: break
    }
    if ValueType.otherIntegers.contains(name), arguments == nil { return .integer(name) }
    if let advice = knownUnsupported[name] {
        throw UnsupportedType(node: Syntax(whole), reason: "`\(name)` has no schema: \(advice)")
    }
    let text = whole.trimmedDescription
    return .named(text, isSelf: text == enclosing)
}
#endif
