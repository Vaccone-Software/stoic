#if STOIC_MACROS
import SwiftSyntax

/// Where the macro writes the library's names. A module selector, so that a
/// type in the consumer's module that happens to be called `Schema` or
/// `Field` cannot change what the generated code means.
let library = "StoicSchema::"

/// The expression that builds the schema of a value of `type`, in a place
/// where the compiler already knows the type (a `Field`'s key path).
///
/// - Parameters:
///   - scalar: constraints (as code) for the innermost value.
///   - collection: constraints for the outermost array or dictionary.
///   - nullable: whether an optional is written as `null`.
///   - format: the argument of `@DateFormat`, `@URLFormat` or `@DataFormat`
///     as written, for the leaf it is about.
func schemaExpression(
    _ type: ValueType, scalar: [String] = [], collection: [String] = [], nullable: Bool = false, format: String = "",
    lossy: Bool = false
) -> String {
    func join(_ parts: [String]) -> String { parts.joined(separator: ", ") }
    switch type {
    case .bool:
        return ".bool"
    case .double:
        return ".double(\(join(scalar)))"
    case .string:
        return ".string(\(join(scalar)))"
    case .json:
        return ".json(\(join(scalar)))"
    case .date:
        return ".date(\(format))"
    case .url:
        return ".url(\(format))"
    case .uuid:
        return ".uuid"
    case .data:
        return ".data(\(format))"
    case .decimal:
        return ".decimal(\(join(scalar)))"
    case .integer(let name):
        switch name {
        case "Int": return ".int(\(join(scalar)))"
        case "Int64": return ".int64(\(join(scalar)))"
        case "UInt64": return ".uint64(\(join(scalar)))"
        default: return scalar.isEmpty ? ".integer(\(name).self)" : ".integer(\(name).self, [\(join(scalar))])"
        }
    case .array(let element):
        let inner = schemaExpression(element, scalar: scalar, format: format)
        return ".\(lossy ? "lossyArray" : "array")(of: \(inner)\(collection.isEmpty ? "" : ", " + join(collection)))"
    case .dictionary(let value):
        let inner = schemaExpression(value, scalar: scalar, format: format)
        return ".dictionary(of: \(inner)\(collection.isEmpty ? "" : ", " + join(collection)))"
    case .optional(let wrapped):
        let inner = schemaExpression(wrapped, scalar: scalar, collection: collection, format: format, lossy: lossy)
        return ".optional(\(inner)\(nullable ? ", nullable: true" : ""))"
    case .secret(let inner):
        let base = schemaExpression(inner, scalar: scalar, collection: collection, format: format, lossy: lossy)
        return ".transform(base: \(base), decode: { Secret($0) }, encode: { $0.reveal() }, describe: \"a secret value\")"
    case .named(let text, let isSelf):
        return isSelf ? ".lazy { \(text).schema }" : "\(text).schema"
    }
}

/// The same, for a place that gives the compiler nothing to infer from (the
/// payload of a union case): the expression is anchored to its type.
func explicitSchemaExpression(_ type: ValueType, typeText: String) -> String {
    if case .named(let text, let isSelf) = type, !isSelf { return "\(text).schema" }
    return "\(library)Schema<\(typeText)>" + schemaExpression(type)
}
#endif
