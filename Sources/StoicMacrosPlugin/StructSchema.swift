#if STOIC_MACROS
import SwiftSyntax

/// `@Schema` on a struct: form (a), an object with a default instance.
func expandStruct(
    _ declaration: StructDeclSyntax, attribute: AttributeSyntax, access: String, reporter: Reporter
) -> String? {
    let name = declaration.name.text
    if let generics = declaration.genericParameterClause {
        reporter.error(
            generics,
            Problem(
                id: "generic-type",
                message: "@Schema cannot describe a generic type: a static property of a generic type belongs to each specialization, and a schema needs one"))
    }
    let model = readFields(of: declaration, enclosing: name, reporter: reporter)
    guard !reporter.hasErrors else { return nil }

    var lines: [String] = []
    for field in model.fields {
        var arguments = [field.keyLiteral, "\\.\(field.property)"]
        let scalar = field.scalar.map(\.constraintCode)
        let collection = field.collection.map(\.constraintCode)
        arguments.append(
            schemaExpression(field.type, scalar: scalar, collection: collection, nullable: field.isNullable))
        if let doc = field.doc { arguments.append("doc: \(swiftLiteral(doc))") }
        if let unit = field.unit { arguments.append("unit: \(unit)") }
        if !field.aliases.isEmpty { arguments.append("aliases: [\(field.aliases.map(\.source).joined(separator: ", "))]") }
        if field.isSecret { arguments.append("secret: true") }
        if let deprecation = field.deprecation { arguments.append("deprecated: \(deprecation)") }
        lines.append("    \(library)Field(\(arguments.joined(separator: ", ")))")
    }

    var options = [String]()
    options.append("\(name).self")
    options.append("default: \(name)()")
    if let doc = documentation(of: declaration) { options.append("doc: \(swiftLiteral(doc))") }
    let body = lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n") + "\n"
    return """
        \(access)static let schema: \(library)Schema<\(name)> = \(library)Schema.object(\(options.joined(separator: ", "))) {\(body)}
        """
}
#endif
