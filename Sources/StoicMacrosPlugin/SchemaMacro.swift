#if STOIC_MACROS
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Schema`: writes a type's schema from its declaration.
///
/// The expansion is a `static let schema` made only of calls to the public
/// StoicSchema API, and the conformance to `Schematic` that lets other
/// schemas refer to it. Nothing in it is private to the macro: the same
/// declaration written by hand behaves the same.
struct SchemaMacro: MemberMacro, ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let text = schemaDeclaration(of: declaration, attribute: node, reporter: Reporter(context)) else {
            return []
        }
        return [DeclSyntax(stringLiteral: text)]
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // A declaration the member expansion refused gets no conformance
        // either: its errors are the useful ones, and a missing `schema` is
        // not another. (The member pass has reported; this one is silent.)
        guard schemaDeclaration(of: declaration, attribute: node, reporter: Reporter(context, silent: true)) != nil
        else { return [] }
        // `Schematic` for every kind; `CaseIterable` too for an enumeration of
        // raw values, whose `allCases` the library reads. (A union is not
        // `CaseIterable`: its cases carry values.)
        let rawEnumeration = declaration.as(EnumDeclSyntax.self).map { !$0.isUnion } ?? false
        let wanted = protocols.compactMap { protocolType -> String? in
            let name = protocolType.trimmedDescription
            if name.hasSuffix("Schematic") { return "\(library)Schematic" }
            if name == "CaseIterable" && rawEnumeration { return "CaseIterable" }
            return nil
        }
        guard !wanted.isEmpty else { return [] }
        return [try ExtensionDeclSyntax("extension \(type.trimmed): \(raw: wanted.joined(separator: ", ")) {}")]
    }
}

/// The text of `static let schema` for `declaration`, or `nil` with the
/// reasons reported.
func schemaDeclaration(
    of declaration: some DeclGroupSyntax, attribute: AttributeSyntax, reporter: Reporter
) -> String? {
    let access = accessPrefix(declaration)
    for member in declaration.memberBlock.members {
        guard let variable = member.decl.as(VariableDeclSyntax.self),
            variable.modifiers.contains(where: { $0.name.text == "static" }),
            let binding = variable.bindings.first(where: { $0.pattern.trimmedDescription == "schema" })
        else { continue }
        reporter.error(
            binding.pattern,
            Problem(
                id: "schema-exists",
                message: "@Schema writes `static let schema`, and this type already has one: remove it, or remove @Schema and keep the schema written by hand"
            ))
        return nil
    }
    let text: String?
    if let structure = declaration.as(StructDeclSyntax.self) {
        text = expandStruct(structure, attribute: attribute, access: access, reporter: reporter)
    } else if let enumeration = declaration.as(EnumDeclSyntax.self) {
        text = expandEnum(enumeration, attribute: attribute, access: access, reporter: reporter)
    } else {
        reporter.error(
            attribute, Problem(id: "unsupported-declaration", message: "@Schema applies to a struct or an enum"))
        return nil
    }
    guard let text, !reporter.hasErrors else { return nil }
    return text
}

/// `public ` or `package ` if the type is, since the generated `schema` must
/// be as visible as the type to satisfy `Schematic`.
func accessPrefix(_ declaration: some DeclGroupSyntax) -> String {
    for modifier in declaration.modifiers {
        switch modifier.name.text {
        case "public", "open": return "public "
        case "package": return "package "
        default: continue
        }
    }
    return ""
}
#endif
