#if STOIC_MACROS
import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct StoicMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        SchemaMacro.self,
        RefinedMacro.self,
        KeyMacro.self,
        SecretMacro.self,
        UnitMacro.self,
        AliasesMacro.self,
        DeprecatedMacro.self,
        NullableMacro.self,
        IgnoredMacro.self,
        PreserveUnknownKeysMacro.self,
        DateFormatMacro.self,
        URLFormatMacro.self,
        DataFormatMacro.self,
        RangeMacro.self,
        GreaterThanMacro.self,
        LessThanMacro.self,
        MultipleOfMacro.self,
        LengthMacro.self,
        PatternMacro.self,
        CountMacro.self,
        UniqueMacro.self,
    ]
}
#else
// Built without the Macros trait there is no swift-syntax to expand with.
// A macro target is an executable, so it still needs an entry point.
@main
enum StoicMacrosUnavailable {
    static func main() {}
}
#endif
