#if STOIC_MACROS
import SwiftDiagnostics
import SwiftSyntax

/// What a case carries.
private enum Payload {
    case none
    /// One value: its schema is the value's, and it is written flat if it is
    /// an object, under the value key if it is not.
    case single(ValueType, text: String)
    /// Several labelled values: an object of their own, keyed by the labels.
    case labelled([(label: String, type: ValueType, text: String)])
}

private struct CaseModel {
    var name: String
    var tag: String
    var tagLiteral: String
    var doc: String?
    var payload: Payload
}

/// `@Schema` on an enumeration: a string or integer enumeration if it has a
/// raw type, a tagged union if its cases carry values.
func expandEnum(
    _ declaration: EnumDeclSyntax, attribute: AttributeSyntax, access: String, reporter: Reporter
) -> String? {
    let name = declaration.name.text
    let arguments = SchemaArguments(attribute)
    if let generics = declaration.genericParameterClause {
        reporter.error(
            generics,
            Problem(
                id: "generic-type",
                message: "@Schema cannot describe a generic type: a static property of a generic type belongs to each specialization, and a schema needs one"))
    }

    // The cases, as written.
    struct Written {
        var element: EnumCaseElementSyntax
        var declaration: EnumCaseDeclSyntax
    }
    var written: [Written] = []
    for member in declaration.memberBlock.members {
        guard let caseDeclaration = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
        for element in caseDeclaration.elements { written.append(Written(element: element, declaration: caseDeclaration)) }
    }
    if written.isEmpty {
        reporter.error(declaration.name, Problem(id: "no-cases", message: "`\(name)` has no cases, so its schema would accept nothing"))
        return nil
    }

    let hasPayloads = written.contains { ($0.element.parameterClause?.parameters.isEmpty ?? true) == false }
    let rawType = rawType(of: declaration, reporter: reporter)

    if hasPayloads {
        arguments.check(allowed: SchemaArguments.unionLabels, kind: "an enum with associated values", reporter: reporter)
        var cases: [CaseModel] = []
        for item in written {
            if let model = readUnionCase(item.element, item.declaration, enclosing: name, reporter: reporter) {
                cases.append(model)
            }
        }
        checkTags(cases, arguments: arguments, written: written.map(\.element), reporter: reporter)
        guard !reporter.hasErrors else { return nil }
        return unionDeclaration(
            name: name, cases: cases, arguments: arguments, doc: documentation(of: declaration), access: access)
    }

    // An enumeration of raw values.
    arguments.check(allowed: [], kind: "an enumeration of raw values", reporter: reporter)
    for item in written {
        for marker in markers(in: item.declaration.attributes) {
            reporter.error(
                marker.node,
                Problem(
                    id: "marker-on-raw-case",
                    message: "\(marker.name) does not apply to the case of an enumeration with a raw type: its raw value is what is written, so give the case one (`case \(item.element.name.text) = \"…\"`)"))
        }
    }
    guard let rawType else {
        if !reporter.hasErrors {
            var fixIts: [FixIt] = []
            if let clause = declaration.inheritanceClause, let first = clause.inheritedTypes.first {
                fixIts = [.inserting("String, ", before: first, "give `\(name)` the raw type `String`")]
            } else {
                fixIts = [.inserting(": String", after: declaration.name, "give `\(name)` the raw type `String`")]
            }
            reporter.error(
                declaration.name,
                Problem(
                    id: "enum-without-raw-type",
                    message: "`\(name)` has no raw type and no associated values, so the schema has nothing to write: give it a `String` or `Int` raw type, or associated values"),
                fixIts: fixIts)
        }
        return nil
    }
    _ = rawType
    guard !reporter.hasErrors else { return nil }
    return "\(access)static let schema: \(library)Schema<\(name)> = \(library)Schema.enumeration(\(name).self)"
}

/// `String` or `Int` if the enumeration says so; otherwise `nil`, with a
/// diagnostic if it names a raw type the schema cannot use.
private func rawType(of declaration: EnumDeclSyntax, reporter: Reporter) -> String? {
    guard let clause = declaration.inheritanceClause else { return nil }
    let unusable: Set<String> = [
        "Double", "Float", "Character", "UInt8", "UInt16", "UInt32", "UInt64", "UInt", "Int8", "Int16", "Int32", "Int64",
        "Substring", "StaticString",
    ]
    for inherited in clause.inheritedTypes {
        let type = inherited.type.trimmedDescription
        if type == "String" || type == "Int" { return type }
        if unusable.contains(type) {
            reporter.error(
                inherited.type,
                Problem(
                    id: "unsupported-raw-type",
                    message: "an enumeration is written as its raw value, and the schema reads only `String` and `Int` raw values, not `\(type)`"))
            return nil
        }
    }
    return nil
}

private func readUnionCase(
    _ element: EnumCaseElementSyntax, _ declaration: EnumCaseDeclSyntax, enclosing: String, reporter: Reporter
) -> CaseModel? {
    let caseName = element.name.text
    var tag = caseName.trimmingBackticks
    var tagLiteral = swiftLiteral(tag)
    var seen: Set<MarkerKind> = []
    for marker in markers(in: declaration.attributes) {
        guard marker.kind == .key else {
            reporter.error(
                marker.node,
                Problem(id: "marker-on-case", message: "\(marker.name) does not apply to a case of a union; a payload's own schema holds its constraints"))
            continue
        }
        if !seen.insert(marker.kind).inserted {
            reporter.error(marker.node, Problem(id: "duplicate-marker", message: "@Key appears twice on `\(caseName)`"))
            continue
        }
        guard let argument = marker.arguments.first, let (value, source) = plainStringLiteral(argument.expression) else {
            reporter.error(marker.node, Problem(id: "argument-not-literal", message: "the argument of @Key must be a string literal, so that the macro can read it"))
            continue
        }
        if value.isEmpty {
            reporter.error(marker.node, Problem(id: "empty-key", message: "a tag cannot be empty"))
            continue
        }
        tag = value
        tagLiteral = source
    }

    var payload = Payload.none
    if let clause = element.parameterClause, !clause.parameters.isEmpty {
        var parts: [(label: String?, type: ValueType, text: String)] = []
        for parameter in clause.parameters {
            do throws(UnsupportedType) {
                let type = try classify(parameter.type, enclosing: enclosing)
                parts.append((parameter.firstName?.text == "_" ? nil : parameter.firstName?.text, type, parameter.type.trimmedDescription))
            } catch {
                reporter.error(error.node, Problem(id: "unsupported-type", message: "`\(caseName)`: \(error.reason)"))
                return nil
            }
        }
        if parts.count == 1 {
            payload = .single(parts[0].type, text: parts[0].text)
        } else if parts.allSatisfy({ $0.label != nil }) {
            payload = .labelled(parts.map { ($0.label!, $0.type, $0.text) })
        } else {
            reporter.error(
                clause,
                Problem(
                    id: "unlabelled-payload",
                    message: "`\(caseName)` carries several values, which are written as an object: name each one (`case \(caseName)(first: …, second: …)`) so that it has a key"))
            return nil
        }
    }
    return CaseModel(
        name: caseName, tag: tag, tagLiteral: tagLiteral, doc: documentation(of: declaration), payload: payload)
}

private func checkTags(
    _ cases: [CaseModel], arguments: SchemaArguments, written: [EnumCaseElementSyntax], reporter: Reporter
) {
    var seen: [String: String] = [:]
    for (model, element) in zip(cases, written) {
        if let first = seen[model.tag] {
            reporter.error(
                element.name,
                Problem(
                    id: "duplicate-tag",
                    message: "`\(model.name)` is written as \"\(model.tag)\", the tag of `\(first)` already; give one a different @Key"))
        } else {
            seen[model.tag] = model.name
        }
    }
    let discriminator = arguments.byLabel["discriminator"].flatMap { plainStringLiteral($0.expression)?.value } ?? "type"
    let valueKey = arguments.byLabel["valueKey"].flatMap { plainStringLiteral($0.expression)?.value } ?? "value"
    if discriminator == valueKey {
        let culprit: Syntax = (arguments.byLabel["valueKey"] ?? arguments.byLabel["discriminator"]).map { Syntax($0) } ?? Syntax(arguments.node)
        reporter.error(
            culprit,
            Problem(id: "discriminator-is-value-key", message: "the discriminator and the value key are both \"\(discriminator)\"; they must differ"))
    }
}

private func unionDeclaration(
    name: String, cases: [CaseModel], arguments: SchemaArguments, doc: String?, access: String
) -> String {
    var options = ["\(name).self"]
    options += arguments.passed(["discriminator", "name"])
    if let doc { options.append("doc: \(swiftLiteral(doc))") }
    options += arguments.passed(["valueKey"])

    var lines: [String] = []
    for model in cases {
        let docArgument = model.doc.map { ", doc: \(swiftLiteral($0))" } ?? ""
        let reference = "\(name).\(model.name)"
        switch model.payload {
        case .none:
            lines.append(
                "    \(library)Case(\(model.tagLiteral), \(reference)\(docArgument)) { if case .\(model.name) = $0 { true } else { false } }"
            )
        case .single(let type, let text):
            let schema = explicitSchemaExpression(type, typeText: text)
            lines.append(
                "    \(library)Case(\(model.tagLiteral), \(schema), \(reference)\(docArgument)) { if case .\(model.name)(let payload) = $0 { payload } else { nil } }"
            )
        case .labelled(let parts):
            let tupleType = "(" + parts.map { "\($0.label): \($0.text)" }.joined(separator: ", ") + ")"
            var object = ["    \(library)Case(\(model.tagLiteral), \(library)Schema.object(\(tupleType).self, name: \(swiftLiteral("\(name).\(model.name.trimmingBackticks)"))) { reader in"]
            for part in parts {
                let expression = schemaExpression(part.type)
                object.append("        let _\(part.label.trimmingBackticks) = reader.field(\(swiftLiteral(part.label.trimmingBackticks)), \\.\(part.label), \(expression))")
            }
            let values = parts.map { "\($0.label): values[_\($0.label.trimmingBackticks)]" }.joined(separator: ", ")
            object.append("        return reader.build { values in (\(values)) }")
            let make = parts.map { "\($0.label): $0.\($0.label)" }.joined(separator: ", ")
            let bindings = parts.map { "let \($0.label.trimmingBackticks)" }.joined(separator: ", ")
            let tuple = parts.map { "\($0.label): \($0.label.trimmingBackticks)" }.joined(separator: ", ")
            object.append(
                "    }, { \(reference)(\(make)) }\(docArgument)) { if case .\(model.name)(\(bindings)) = $0 { (\(tuple)) } else { nil } }"
            )
            lines.append(object.joined(separator: "\n"))
        }
    }
    return """
        \(access)static let schema: \(library)Schema<\(name)> = \(library)Schema.union(\(options.joined(separator: ", "))) {
        \(lines.joined(separator: "\n"))
        }
        """
}
#endif

#if STOIC_MACROS
extension EnumDeclSyntax {
    /// Whether any case carries a value, which makes the enumeration a union
    /// rather than a list of raw values.
    var isUnion: Bool {
        memberBlock.members.contains { member in
            guard let caseDeclaration = member.decl.as(EnumCaseDeclSyntax.self) else { return false }
            return caseDeclaration.elements.contains { $0.parameterClause?.parameters.isEmpty == false }
        }
    }
}
#endif
