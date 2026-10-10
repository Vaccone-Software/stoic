#if STOIC_MACROS
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Refined(Double.self, .range(0.1...10), .finite)`: a named refinement.
///
/// The macro adds the two requirements of `Refinement`, `Base` and
/// `constraints`, to the type it is attached to, and checks the constraints
/// as it checks the attributes of `@Schema`: that each fits the base type,
/// that a range is not empty. The constraints are written as the library's
/// own `Constraint` values and copied unchanged.
struct RefinedMacro: MemberMacro, ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let members = refinement(of: declaration, attribute: node, reporter: Reporter(context)) else { return [] }
        return [
            DeclSyntax(stringLiteral: "\(members.access)typealias Base = \(members.base)"),
            DeclSyntax(
                stringLiteral:
                    "\(members.access)static var constraints: [\(library)Constraint] { [\(members.constraints.joined(separator: ", "))] }"
            ),
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard refinement(of: declaration, attribute: node, reporter: Reporter(context, silent: true)) != nil,
            protocols.contains(where: { $0.trimmedDescription.hasSuffix("Refinement") })
        else { return [] }
        return [try ExtensionDeclSyntax("extension \(type.trimmed): \(raw: library)Refinement {}")]
    }
}

private struct RefinementMembers {
    var access: String
    var base: String
    var constraints: [String]
}

private func refinement(
    of declaration: some DeclGroupSyntax, attribute: AttributeSyntax, reporter: Reporter
) -> RefinementMembers? {
    guard declaration.is(EnumDeclSyntax.self) || declaration.is(StructDeclSyntax.self) else {
        reporter.error(
            attribute,
            Problem(id: "refined-declaration", message: "@Refined applies to an enum or a struct, which names the refinement"))
        return nil
    }
    guard case .argumentList(let list)? = attribute.arguments, let first = list.first else {
        reporter.error(
            attribute,
            Problem(id: "refined-base", message: "@Refined needs the base type first, written `Double.self`, then the constraints"))
        return nil
    }
    guard let member = first.expression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "self",
        let baseExpression = member.base
    else {
        reporter.error(
            first.expression,
            Problem(
                id: "refined-base",
                message: "the first argument of @Refined is the base type, written `Double.self`, not \(first.expression.trimmedDescription)"
            ))
        return nil
    }
    let baseText = baseExpression.trimmedDescription
    let constraints = Array(list.dropFirst())
    if constraints.isEmpty {
        reporter.error(
            attribute,
            Problem(id: "refined-empty", message: "a refinement with no constraints refines nothing: add `.range(…)`, `.length(…)` or another"))
        return nil
    }

    // What the constraints say, as far as the macro can read them.
    var scalar: [Marker] = []
    var collection: [Marker] = []
    for argument in constraints {
        guard let marker = constraint(from: argument.expression) else { continue }
        if marker.kind.constrainsCollections { collection.append(marker) } else { scalar.append(marker) }
    }
    var baseType: ValueType?
    do throws(UnsupportedType) {
        baseType = try classify(TypeSyntax(stringLiteral: baseText), enclosing: "")
    } catch {
        reporter.error(first.expression, Problem(id: "unsupported-type", message: "the base type: \(error.reason)"))
    }
    if let baseType {
        // A refinement's constraints are about the base value itself, so a
        // number constraint does not reach inside an array the way an
        // attribute on a property does.
        let topLevel: ValueType = baseType.collection == nil && !baseType.isOptional ? baseType : .json
        let subject = Subject(name: "the base type", typeText: baseText)
        checkFit(scalar: scalar, collection: [], type: topLevel, subject: subject, reporter: reporter)
        checkFit(scalar: [], collection: collection, type: baseType, subject: subject, reporter: reporter)
        if !reporter.hasErrors {
            _ = checkCoherence(scalar: scalar, collection: collection, subject: subject, anchor: Syntax(attribute), reporter: reporter)
        }
    }
    guard !reporter.hasErrors else { return nil }
    return RefinementMembers(
        access: accessPrefix(declaration), base: baseText, constraints: constraints.map { $0.expression.trimmedDescription })
}

/// A `.range(…)`, `.length(…)`, `.unique` and the like, read as the
/// attribute of the same name would be. Anything else (a constant, a call
/// to a helper) is the library's to check.
private func constraint(from expression: ExprSyntax) -> Marker? {
    var name: String?
    var arguments: [LabeledExprSyntax] = []
    if let call = expression.as(FunctionCallExprSyntax.self), let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
        callee.base == nil
    {
        name = callee.declName.baseName.text
        arguments = Array(call.arguments)
    } else if let access = expression.as(MemberAccessExprSyntax.self), access.base == nil {
        name = access.declName.baseName.text
    }
    guard let name, let kind = MarkerKind(rawValue: name.prefix(1).uppercased() + name.dropFirst()), kind.isConstraint
    else { return nil }
    return Marker(kind: kind, node: Syntax(expression), arguments: arguments, name: "." + name)
}
#endif
