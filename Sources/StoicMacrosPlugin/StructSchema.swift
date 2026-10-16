#if STOIC_MACROS
import SwiftSyntax

/// `@Schema` on a struct: form (a), an object with a default instance, when
/// every property has a default; otherwise form (b), built by the memberwise
/// initialiser.
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

    if model.usesReader { return readerSchema(of: declaration, model: model, arguments: arguments, access: access) }

    var lines: [String] = []
    for field in model.fields {
        var arguments = [field.keyLiteral, "\\.\(field.property)"]
        arguments.append(schemaExpression(of: field, nullable: field.isNullable))
        arguments += field.descriptionArguments
        lines.append("    \(library)Field(\(arguments.joined(separator: ", ")))")
    }

    var options = ["\(name).self"]
    options += arguments.passed(["name"])
    options.append("default: \(name)()")
    options += arguments.passed(["unknownKeys", "spellings"])
    if let doc = documentation(of: declaration) { options.append("doc: \(swiftLiteral(doc))") }
    options += arguments.passed(["version", "versionKey", "missingVersion", "migrations"])
    if let preserving = model.preserving { options.append("preservingUnknownKeysIn: \\\(name).\(preserving)") }
    let body = lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n") + "\n"
    return """
        \(access)static let schema: \(library)Schema<\(name)> = \(library)Schema.object(\(options.joined(separator: ", "))) {\(body)}
        """
}

/// Form (b): some property has no default, so the value is built by the
/// memberwise initialiser from fields read one by one. A property without a
/// default is required; an optional one may also be `null`; the rest keep
/// the default they were written with.
private func readerSchema(
    of declaration: StructDeclSyntax, model: StructModel, arguments: SchemaArguments, access: String
) -> String {
    let name = declaration.name.text
    var lines: [String] = []
    var labels: [String] = []
    for (index, field) in model.fields.enumerated() {
        let slot = "slot\(index)"
        var parts = [field.keyLiteral, "\\.\(field.property)"]
        // `T?` with nothing written is "none", whether the key is missing or null.
        let implicitNone = field.defaultValue == nil && field.type.isOptional
        parts.append(schemaExpression(of: field, nullable: field.isNullable || implicitNone))
        if let value = field.defaultValue { parts.append("default: \(value.trimmedDescription)") }
        parts += field.descriptionArguments
        lines.append("    let \(slot) = f.field(\(parts.joined(separator: ", ")))")
        labels.append("\(field.property): v[\(slot)]")
    }
    if let preserving = model.preserving {
        lines.append("    let preserved = f.unknownKeys(\\\(name).\(preserving))")
        labels.append("\(preserving): v[preserved]")
    }
    lines.append("    return f.build { v in \(name)(\(labels.joined(separator: ", "))) }")

    var options = ["\(name).self"]
    options += arguments.passed(["name", "unknownKeys", "spellings"])
    if let doc = documentation(of: declaration) { options.append("doc: \(swiftLiteral(doc))") }
    options += arguments.passed(["version", "versionKey", "missingVersion", "migrations"])
    return """
        \(access)static let schema: \(library)Schema<\(name)> = \(library)Schema.object(\(options.joined(separator: ", "))) { f in
        \(lines.joined(separator: "\n"))
        }
        """
}

extension FieldModel {
    /// The arguments after the schema, in the order the library's `Field` and
    /// `ObjectReader.field` share.
    var descriptionArguments: [String] {
        var arguments: [String] = []
        if let doc { arguments.append("doc: \(swiftLiteral(doc))") }
        if let unit { arguments.append("unit: \(unit)") }
        if !aliases.isEmpty { arguments.append("aliases: [\(aliases.map(\.source).joined(separator: ", "))]") }
        if isSecret { arguments.append("secret: true") }
        if let deprecation { arguments.append("deprecated: \(deprecation)") }
        return arguments
    }
}

/// The schema expression of a field, with its constraints and format.
private func schemaExpression(of field: FieldModel, nullable: Bool) -> String {
    schemaExpression(
        field.type, scalar: field.scalar.map(\.constraintCode), collection: field.collection.map(\.constraintCode),
        nullable: nullable, format: field.format?.arguments.first?.expression.trimmedDescription ?? "",
        lossy: field.isLossy, codable: field.isCodable, codableExamples: field.codableExamples)
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
