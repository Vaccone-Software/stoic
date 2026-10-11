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
    let arguments = SchemaArguments(attribute)
    arguments.check(allowed: SchemaArguments.structLabels, kind: "a struct", reporter: reporter)
    let model = readFields(of: declaration, enclosing: name, reporter: reporter)
    checkKeys(of: model, arguments: arguments, reporter: reporter)
    guard !reporter.hasErrors else { return nil }

    var lines: [String] = []
    for field in model.fields {
        var arguments = [field.keyLiteral, "\\.\(field.property)"]
        let scalar = field.scalar.map(\.constraintCode)
        let collection = field.collection.map(\.constraintCode)
        arguments.append(
            schemaExpression(
                field.type, scalar: scalar, collection: collection, nullable: field.isNullable,
                format: field.format?.arguments.first?.expression.trimmedDescription ?? ""))
        if let doc = field.doc { arguments.append("doc: \(swiftLiteral(doc))") }
        if let unit = field.unit { arguments.append("unit: \(unit)") }
        if !field.aliases.isEmpty { arguments.append("aliases: [\(field.aliases.map(\.source).joined(separator: ", "))]") }
        if field.isSecret { arguments.append("secret: true") }
        if let deprecation = field.deprecation { arguments.append("deprecated: \(deprecation)") }
        lines.append("    \(library)Field(\(arguments.joined(separator: ", ")))")
    }

    var options = ["\(name).self"]
    options += arguments.passed(["name"])
    options.append("default: \(name)()")
    options += arguments.passed(["unknownKeys"])
    if let doc = documentation(of: declaration) { options.append("doc: \(swiftLiteral(doc))") }
    options += arguments.passed(["version", "versionKey", "missingVersion", "migrations"])
    if let preserving = model.preserving { options.append("preservingUnknownKeysIn: \\\(name).\(preserving)") }
    let body = lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n") + "\n"
    return """
        \(access)static let schema: \(library)Schema<\(name)> = \(library)Schema.object(\(options.joined(separator: ", "))) {\(body)}
        """
}

/// Everything about the keys that would otherwise trap when the schema is
/// first built: a key or alias declared twice, the version key used as a
/// field, `migrations` with no version to lead to, and unknown keys both
/// preserved and given a policy.
private func checkKeys(of model: StructModel, arguments: SchemaArguments, reporter: Reporter) {
    var claimed: [String: String] = [:]
    func claim(_ spelling: String, by owner: String, at node: Syntax) {
        if let first = claimed[spelling] {
            let message =
                first == owner
                ? "the alias \"\(spelling)\" is `\(owner)`'s own key already; an alias is another spelling"
                : "the key \"\(spelling)\" is `\(owner)`'s, and `\(first)` already uses it; give one a different @Key or alias"
            reporter.error(node, Problem(id: "duplicate-key", message: message))
        } else {
            claimed[spelling] = owner
        }
    }
    for field in model.fields {
        claim(field.key, by: field.property, at: field.keyNode)
        for alias in field.aliases { claim(alias.value, by: field.property, at: alias.node) }
    }

    if arguments.has("migrations") && !arguments.has("version") {
        reporter.error(
            arguments.byLabel["migrations"]!,
            Problem(id: "migrations-without-version", message: "`migrations:` lead to the current `version:`, and none is given"))
    }
    if let version = arguments.byLabel["version"], let value = number(of: version.expression), value < 1 || value != value.rounded() {
        reporter.error(version, Problem(id: "bad-version", message: "a version is a positive integer, not \(version.expression.trimmedDescription)"))
    }
    if arguments.has("versionKey") && !arguments.has("version") {
        reporter.error(arguments.byLabel["versionKey"]!, Problem(id: "version-key-without-version", message: "`versionKey:` names where `version:` is written, and none is given"))
    }
    if arguments.has("missingVersion") && !arguments.has("version") {
        reporter.error(arguments.byLabel["missingVersion"]!, Problem(id: "missing-version-without-version", message: "`missingVersion:` says what a document without a version means, and there is no `version:`"))
    }
    if arguments.has("version") {
        let versionKey = arguments.byLabel["versionKey"].flatMap { plainStringLiteral($0.expression)?.value } ?? "version"
        if let owner = claimed[versionKey], let node = arguments.byLabel["version"] {
            reporter.error(
                node,
                Problem(
                    id: "version-key-is-a-field",
                    message: "\"\(versionKey)\" holds the document's version, and `\(owner)` is written under it; give the field another @Key or set `versionKey:`"))
        }
    }
    if let policy = arguments.byLabel["unknownKeys"] {
        let text = policy.expression.trimmedDescription
        if model.preserving != nil {
            reporter.error(
                policy,
                Problem(
                    id: "conflicting-unknown-keys",
                    message: "`unknownKeys:` and @PreserveUnknownKeys both say what happens to unknown keys; the property that keeps them makes the policy `.preserve`, so drop `unknownKeys:`"))
        } else if text == ".preserve" {
            reporter.error(
                policy,
                Problem(
                    id: "preserve-without-property",
                    message: "`.preserve` keeps unknown keys in a property: mark a `JSONObject` property with @PreserveUnknownKeys"))
        }
    }
}
#endif
