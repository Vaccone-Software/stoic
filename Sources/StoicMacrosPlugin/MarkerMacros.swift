#if STOIC_MACROS
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// The attributes that `@Schema` reads. Each expands to nothing; what they
/// add is a check that they are used where `@Schema` will see them.
protocol MarkerMacro: PeerMacro {
    static var kind: MarkerKind { get }
}

extension MarkerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let enclosing = context.lexicalContext.first
        let attributes: AttributeListSyntax?
        if let structure = enclosing?.as(StructDeclSyntax.self) {
            attributes = structure.attributes
        } else if let enumeration = enclosing?.as(EnumDeclSyntax.self) {
            attributes = enumeration.attributes
        } else {
            attributes = nil
        }
        let inSchema = attributes?.contains { element in
            guard case .attribute(let attribute) = element else { return false }
            let name = attribute.attributeName.trimmedDescription
            return name == "Schema" || name.hasSuffix(".Schema")
        } ?? false
        if !inSchema {
            context.diagnose(
                Diagnostic(
                    node: Syntax(node),
                    message: Message(
                        problem: Problem(
                            id: "marker-outside-schema",
                            message: "\(kind.spelling) means something only inside a type marked @Schema"),
                        severity: .error)))
        }
        return []
    }
}

struct KeyMacro: MarkerMacro { static let kind = MarkerKind.key }
struct SecretMacro: MarkerMacro { static let kind = MarkerKind.secret }
struct UnitMacro: MarkerMacro { static let kind = MarkerKind.unit }
struct AliasesMacro: MarkerMacro { static let kind = MarkerKind.aliases }
struct DeprecatedMacro: MarkerMacro { static let kind = MarkerKind.deprecated }
struct NullableMacro: MarkerMacro { static let kind = MarkerKind.nullable }
struct IgnoredMacro: MarkerMacro { static let kind = MarkerKind.ignored }

struct PreserveUnknownKeysMacro: MarkerMacro { static let kind = MarkerKind.preserveUnknownKeys }
struct DateFormatMacro: MarkerMacro { static let kind = MarkerKind.dateFormat }
struct URLFormatMacro: MarkerMacro { static let kind = MarkerKind.urlFormat }
struct DataFormatMacro: MarkerMacro { static let kind = MarkerKind.dataFormat }
struct RangeMacro: MarkerMacro { static let kind = MarkerKind.range }
struct GreaterThanMacro: MarkerMacro { static let kind = MarkerKind.greaterThan }
struct LessThanMacro: MarkerMacro { static let kind = MarkerKind.lessThan }
struct MultipleOfMacro: MarkerMacro { static let kind = MarkerKind.multipleOf }
struct LengthMacro: MarkerMacro { static let kind = MarkerKind.length }
struct PatternMacro: MarkerMacro { static let kind = MarkerKind.pattern }
struct CountMacro: MarkerMacro { static let kind = MarkerKind.count }
struct UniqueMacro: MarkerMacro { static let kind = MarkerKind.unique }
#endif
