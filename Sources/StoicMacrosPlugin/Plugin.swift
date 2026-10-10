#if STOIC_MACROS
import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct StoicMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = []
}
#else
// Built without the Macros trait there is no swift-syntax to expand with.
// A macro target is an executable, so it still needs an entry point.
@main
enum StoicMacrosUnavailable {
    static func main() {}
}
#endif
