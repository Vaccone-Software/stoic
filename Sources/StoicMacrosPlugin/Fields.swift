#if STOIC_MACROS
import SwiftDiagnostics
import SwiftSyntax

/// A stored property of the struct, understood.
struct FieldModel {
    /// The property, as written (with backticks if it needs them).
    var property: String
    /// The key in JSON, unquoted.
    var key: String
    /// The key as a Swift literal.
    var keyLiteral: String
    var type: ValueType
    var typeText: String
    var doc: String?
    var unit: String?
    var aliases: [(value: String, source: String, node: Syntax)] = []
    /// The default value as written, if there is one.
    var defaultValue: ExprSyntax?
    /// Whether the property is a `let`, which only the reader form can fill.
    var isConstant = false
    var deprecation: String?
    var isSecret = false
    var isNullable = false
    /// `@Lossy`: the outermost array drops the elements that do not decode.
    var isLossy = false
    /// `@Codable`: the named type inside is read by `JSONDecoder`, not by a schema.
    var isCodable = false
    /// The `examples:` argument of `@Codable` as written, if it has one.
    var codableExamples: String?
    var scalar: [Marker] = []
    var collection: [Marker] = []
    /// `@DateFormat`, `@URLFormat` or `@DataFormat`: it reaches the innermost value.
    var format: Marker?
    /// The declaration, for diagnostics about the field as a whole.
    var node: Syntax
    /// The node a diagnostic about the key points at.
    var keyNode: Syntax
}

/// What the struct's members came to.
struct StructModel {
    var fields: [FieldModel] = []
    /// Whether some property has no default, so the schema cannot start from
    /// a default instance and builds the value from the memberwise
    /// initialiser instead (form (b)).
    var usesReader = false
    /// The property that receives unknown keys, if one is marked.
    var preserving: String?
    var preservingNode: Syntax?
}

/// Reads the stored properties of `declaration`, reporting everything that
/// stops one from being a field.
func readFields(of declaration: StructDeclSyntax, enclosing: String, reporter: Reporter) -> StructModel {
    var model = StructModel()
    var hasInit = false
    var hasPlainInit = false
    for member in declaration.memberBlock.members {
        if let initializer = member.decl.as(InitializerDeclSyntax.self) {
            hasInit = true
            if initializer.signature.parameterClause.parameters.isEmpty { hasPlainInit = true }
        }
    }
    // A property with no default means there is no `init()` to start from,
    // unless the type writes one. The memberwise initialiser is what builds
    // the value, and it exists only while the type declares no initialiser.
    model.usesReader = !hasInit && declaration.memberBlock.members.contains { member in
        guard let variable = member.decl.as(VariableDeclSyntax.self), !isStatic(variable),
            !markers(in: variable.attributes).contains(where: { $0.kind == .ignored })
        else { return false }
        return variable.bindings.contains { !isComputed($0) && $0.initializer == nil && $0.pattern.is(IdentifierPatternSyntax.self) }
    }
    for member in declaration.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
        let found = markers(in: variable.attributes)
        if isStatic(variable) {
            for marker in found {
                reporter.error(
                    marker.node,
                    Problem(
                        id: "static-property",
                        message: "\(marker.name) on a static property: a schema describes the instance's stored properties"))
            }
            continue
        }
        if found.contains(where: { $0.kind == .ignored }) {
            readIgnored(variable, markers: found, model: model, reporter: reporter)
            continue
        }
        for binding in variable.bindings {
            if let field = readField(binding, in: variable, markers: found, enclosing: enclosing, model: &model, reporter: reporter) {
                model.fields.append(field)
            }
        }
    }
    if hasInit && !hasPlainInit {
        reporter.error(
            declaration.name,
            Problem(
                id: "no-default-init",
                message: "`\(enclosing)` declares initializers but no `init()`, and the schema builds its default instance with `\(enclosing)()`; add `init() {}` (every property needs a default)"))
    }
    return model
}

private func isStatic(_ variable: VariableDeclSyntax) -> Bool {
    variable.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
}

/// Whether a binding computes its value, so that it stores nothing.
private func isComputed(_ binding: PatternBindingSyntax) -> Bool {
    guard let accessors = binding.accessorBlock else { return false }
    switch accessors.accessors {
    case .getter:
        return true
    case .accessors(let list):
        return !list.allSatisfy { ["willSet", "didSet"].contains($0.accessorSpecifier.text) }
    }
}

/// A property marked `@Ignored` is not a field, so it takes no other marker.
/// The memberwise initialiser still has a parameter for it, which the schema
/// leaves to its default, so in form (b) it needs one.
private func readIgnored(
    _ variable: VariableDeclSyntax, markers found: [Marker], model: StructModel, reporter: Reporter
) {
    for marker in found where marker.kind != .ignored {
        reporter.error(
            marker.node,
            Problem(
                id: "ignored-with-marker",
                message: "\(marker.name) has no meaning on a property marked `@Ignored`, which the schema leaves out"))
    }
    guard model.usesReader else { return }
    for binding in variable.bindings where !isComputed(binding) && binding.initializer == nil {
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
        let optional = variable.bindingSpecifier.text == "var" && binding.typeAnnotation?.type.is(OptionalTypeSyntax.self) == true
        if !optional {
            reporter.error(
                pattern,
                Problem(
                    id: "ignored-without-default",
                    message: "`\(pattern.identifier.text)` is left out of the schema, so the value is built without it: give it a default"))
        }
    }
}

private func readField(
    _ binding: PatternBindingSyntax,
    in variable: VariableDeclSyntax,
    markers found: [Marker],
    enclosing: String,
    model: inout StructModel,
    reporter: Reporter
) -> FieldModel? {
    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
        reporter.error(
            binding.pattern,
            Problem(id: "pattern-property", message: "declare one property per name: the schema needs each property's name and type"))
        return nil
    }
    // Computed properties are not stored, so they are not part of the value.
    if isComputed(binding) {
        for marker in found {
            reporter.error(
                marker.node,
                Problem(
                    id: "marker-on-computed",
                    message: "\(marker.name) on a computed property: a schema describes stored properties, and `\(pattern.identifier.text)` stores nothing"),
                fixIts: marker.node.is(AttributeSyntax.self) ? [.removing(marker.node, "remove \(marker.name)")] : [])
        }
        return nil
    }
    let name = pattern.identifier.text
    let isConstant = variable.bindingSpecifier.text == "let"
    let startErrors = reporter.errorCount
    // A constant is filled by the initialiser, which is how the reader form
    // builds the value; the default instance form writes to the property.
    if isConstant && (!model.usesReader || binding.initializer != nil) {
        reporter.error(
            pattern,
            Problem(
                id: "constant-property",
                message: "`\(name)` is a constant, and a schema writes to the properties it decodes into; declare it `var`, or mark it `@Ignored`"),
            fixIts: [.replacing(variable.bindingSpecifier, with: "var", "declare `\(name)` with `var`")])
    }

    // The type: written, or read off a literal default.
    var typeNode: TypeSyntax?
    var typeText: String?
    if let annotation = binding.typeAnnotation {
        typeNode = annotation.type
        typeText = annotation.type.trimmedDescription
    } else if let value = binding.initializer?.value, let inferred = literalType(of: value) {
        typeText = inferred
        typeNode = TypeSyntax(IdentifierTypeSyntax(name: .identifier(inferred)))
    } else if let value = binding.initializer?.value, let constructed = constructedType(by: value) {
        typeText = constructed
        typeNode = TypeSyntax(IdentifierTypeSyntax(name: .identifier(constructed)))
    } else {
        reporter.error(
            pattern,
            Problem(
                id: "untyped-property",
                message: "the macro cannot see the type of `\(name)`: it reads types as they are written, so declare it (`var \(name): Type = …`)"))
        return nil
    }

    var type: ValueType?
    if let typeNode {
        do throws(UnsupportedType) {
            type = try classify(typeNode, enclosing: enclosing)
        } catch {
            reporter.error(
                error.node, Problem(id: "unsupported-type", message: "`\(name)`: \(error.reason)"))
        }
    }

    var field = FieldModel(
        property: name, key: name.trimmingBackticks, keyLiteral: swiftLiteral(name.trimmingBackticks),
        type: type ?? .bool, typeText: typeText ?? "", doc: documentation(of: variable),
        defaultValue: binding.initializer?.value, isConstant: isConstant, node: Syntax(binding), keyNode: Syntax(pattern))
    readMarkers(found, into: &field, model: &model, reporter: reporter)
    if let type {
        checkMarkersAgainstType(found, type: type, field: field, reporter: reporter)
        checkConstraints(of: &field, type: type, reporter: reporter)
    }
    if type?.isSecret == true { field.isSecret = true }
    // The property that keeps unknown keys is read by the schema, not a field of it.
    if found.contains(where: { $0.kind == .preserveUnknownKeys }) { return nil }
    return reporter.errorCount > startErrors || type == nil ? nil : field
}

extension String {
    var trimmingBackticks: String {
        hasPrefix("`") && hasSuffix("`") && count >= 2 ? String(dropFirst().dropLast()) : self
    }
}

/// The type of `Name(…)` or `Outer.Name(…)`: a call whose callee is spelt as
/// a type. (A function with a capital letter would fool this, and the
/// generated code would then fail to compile, naming it.)
private func constructedType(by expression: ExprSyntax) -> String? {
    guard let call = expression.as(FunctionCallExprSyntax.self) else { return nil }
    let callee = call.calledExpression
    func isTypeName(_ expression: ExprSyntax) -> Bool {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text.first?.isUppercase == true && reference.argumentNames == nil
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
            return member.declName.baseName.text.first?.isUppercase == true && isTypeName(base)
        }
        return false
    }
    return isTypeName(callee) ? callee.trimmedDescription : nil
}

/// The type a literal has when Swift infers it.
private func literalType(of expression: ExprSyntax) -> String? {
    if expression.is(IntegerLiteralExprSyntax.self) { return "Int" }
    if expression.is(FloatLiteralExprSyntax.self) { return "Double" }
    if expression.is(BooleanLiteralExprSyntax.self) { return "Bool" }
    if expression.is(StringLiteralExprSyntax.self) { return "String" }
    if let prefix = expression.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" {
        return literalType(of: prefix.expression)
    }
    return nil
}

private func readMarkers(
    _ found: [Marker], into field: inout FieldModel, model: inout StructModel, reporter: Reporter
) {
    var seen: Set<MarkerKind> = []
    for marker in found {
        if !seen.insert(marker.kind).inserted {
            reporter.error(
                marker.node,
                Problem(id: "duplicate-marker", message: "\(marker.name) appears twice on `\(field.property)`"),
                fixIts: [.removing(marker.node, "remove the second \(marker.name)")])
            continue
        }
        switch marker.kind {
        case .key:
            guard let (value, source) = stringArgument(marker, reporter: reporter) else { continue }
            if value.isEmpty {
                reporter.error(marker.node, Problem(id: "empty-key", message: "a key cannot be empty"))
                continue
            }
            field.key = value
            field.keyLiteral = source
            field.keyNode = Syntax(marker.node)
        case .secret:
            field.isSecret = true
        case .unit:
            guard let (_, source) = stringArgument(marker, reporter: reporter) else { continue }
            field.unit = source
        case .aliases:
            for argument in marker.arguments {
                guard let (value, source) = plainStringLiteral(argument.expression) else {
                    reporter.error(
                        argument.expression,
                        Problem(id: "alias-not-literal", message: "an alias must be a string literal, so that it can be checked against the other keys"))
                    continue
                }
                field.aliases.append((value, source, Syntax(argument.expression)))
            }
        case .deprecated:
            if let argument = marker.arguments.first {
                guard let (_, source) = plainStringLiteral(argument.expression) else {
                    reporter.error(argument.expression, Problem(id: "deprecation-not-literal", message: "the deprecation message must be a string literal"))
                    continue
                }
                field.deprecation = source
            } else {
                field.deprecation = "\"\""
            }
        case .nullable:
            field.isNullable = true
        case .lossy:
            field.isLossy = true
        case .codable:
            field.isCodable = true
            field.codableExamples = marker.arguments.first?.expression.trimmedDescription
        case .ignored:
            break
        case .unknownCase:
            reporter.error(
                marker.node,
                Problem(id: "unknown-case-on-property", message: "@UnknownCase goes on a case of an enumeration, not on a property"),
                fixIts: marker.removalFixIts)
        case .preserveUnknownKeys:
            if model.preserving != nil {
                reporter.error(
                    marker.node,
                    Problem(id: "second-preserve", message: "only one property can keep the unknown keys, and `\(model.preserving!)` already does"))
            }
            if field.typeText != "JSONObject" && field.typeText != "StoicJSON.JSONObject" {
                reporter.error(
                    marker.node,
                    Problem(
                        id: "preserve-type",
                        message: "@PreserveUnknownKeys needs a property of type `JSONObject`, and `\(field.property)` is `\(field.typeText)`"))
            }
            model.preserving = field.property
            model.preservingNode = Syntax(marker.node)
        case .range, .greaterThan, .lessThan, .multipleOf, .length, .pattern, .finite:
            field.scalar.append(marker)
        case .count, .unique:
            field.collection.append(marker)
        case .dateFormat, .urlFormat, .dataFormat:
            field.format = marker
        }
    }
}

/// The markers that are about the property as a whole.
private func checkMarkersAgainstType(_ found: [Marker], type: ValueType, field: FieldModel, reporter: Reporter) {
    for marker in found {
        switch marker.kind {
        case .nullable where !type.isOptional:
            reporter.error(
                marker.node,
                Problem(
                    id: "nullable-not-optional",
                    message: "@Nullable says that `nil` is written as `null`, and `\(field.property)` is not optional"),
                fixIts: [.removing(marker.node, "remove @Nullable")])
        case .codable where type.leaf != .named:
            reporter.error(
                marker.node,
                Problem(
                    id: "codable-not-named",
                    message: "@Codable reads a named type with `JSONDecoder` in place of a schema, and `\(field.property)` is `\(field.typeText)`, which has a schema of its own"),
                fixIts: marker.removalFixIts)
        case .lossy where type.collection?.isArray != true:
            reporter.error(
                marker.node,
                Problem(
                    id: "lossy-not-array",
                    message: "@Lossy drops the invalid elements of an array, and `\(field.property)` is `\(field.typeText)`"),
                fixIts: marker.removalFixIts)
        case .dateFormat, .urlFormat, .dataFormat:
            let subject = marker.kind.formatSubject
            let leaf = type.leaf
            let fits: Bool
            switch (marker.kind, type.innermost) {
            case (.dateFormat, .date), (.urlFormat, .url), (.dataFormat, .data): fits = true
            default: fits = false
            }
            if !fits {
                let message: String
                if leaf == .named {
                    message =
                        "\(marker.name) cannot be applied to `\(field.property)`: the macro cannot look inside `\(field.typeText)`, so it cannot tell that it is a \(subject). Put the format in that type's own schema"
                } else {
                    message = "\(marker.name) is about a `\(subject)`, and `\(field.property)` is `\(field.typeText)`"
                }
                reporter.error(
                    marker.node, Problem(id: "format-type-mismatch", message: message), fixIts: marker.removalFixIts)
            }
        case .secret where type.isSecret:
            reporter.warning(
                marker.node,
                Problem(
                    id: "redundant-secret",
                    message: "`\(field.property)` is a `Secret` already, so it is a secret field without @Secret"),
                fixIts: [.removing(marker.node, "remove @Secret")])
        default:
            break
        }
    }
}

/// The single string literal a marker takes, or a diagnostic.
private func stringArgument(_ marker: Marker, reporter: Reporter) -> (value: String, source: String)? {
    guard let argument = marker.arguments.first else {
        reporter.error(marker.node, Problem(id: "missing-argument", message: "\(marker.name) needs a string literal"))
        return nil
    }
    guard let literal = plainStringLiteral(argument.expression) else {
        reporter.error(
            argument.expression,
            Problem(id: "argument-not-literal", message: "the argument of \(marker.name) must be a string literal, so that the macro can read it"))
        return nil
    }
    return literal
}
#endif
