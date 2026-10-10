#if STOIC_MACROS
import SwiftDiagnostics
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing

@testable import StoicMacrosPlugin

/// Every macro the plugin provides, as the expander needs to know them.
let allMacros: [String: MacroSpec] = [
    "Schema": MacroSpec(type: SchemaMacro.self, conformances: ["Schematic", "CaseIterable"]),
    "Key": MacroSpec(type: KeyMacro.self),
    "Secret": MacroSpec(type: SecretMacro.self),
    "Unit": MacroSpec(type: UnitMacro.self),
    "Aliases": MacroSpec(type: AliasesMacro.self),
    "Deprecated": MacroSpec(type: DeprecatedMacro.self),
    "Nullable": MacroSpec(type: NullableMacro.self),
    "Ignored": MacroSpec(type: IgnoredMacro.self),
]

/// A diagnostic at a line and column of the source passed to ``expand``.
func problem(
    _ message: String, _ line: Int, _ column: Int, _ severity: DiagnosticSeverity = .error,
    fixIts: [String] = []
) -> DiagnosticSpec {
    DiagnosticSpec(
        message: message, line: line, column: column, severity: severity, fixIts: fixIts.map { FixItSpec(message: $0) })
}

/// Expands `source` and compares the result with `expanded` (and the
/// diagnostics with `diagnostics`), recording each difference as a Swift
/// Testing issue at the caller's line.
func expand(
    _ source: String,
    diagnostics: [DiagnosticSpec] = [],
    to expanded: String,
    macros: [String: MacroSpec] = allMacros,
    fixIts: [String]? = nil,
    fixed: String? = nil,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) {
    let sourceLocation = SourceLocation(
        fileID: "\(fileID)", filePath: "\(filePath)", line: Int(line), column: Int(column))
    assertMacroExpansion(
        source, expandedSource: expanded, diagnostics: diagnostics, macroSpecs: macros,
        applyFixIts: fixIts, fixedSource: fixed,
        failureHandler: { failure in
            if expanded.isEmpty, diagnostics.isEmpty, failure.message.hasPrefix("Expected 0 diagnostics") {
                print("RECORDDIAG \(filePath):\(line)\n\(failure.message)\nENDRECORD")
            }
            if expanded.isEmpty, let range = failure.message.firstRange(of: "Actual expanded source:\n") {
                // Recording mode: an empty expectation prints what to put there.
                print("RECORD \(filePath):\(line)\n\(failure.message[range.upperBound...])\nENDRECORD")
            }
            Issue.record(Comment(rawValue: failure.message), sourceLocation: sourceLocation)
        },
        fileID: fileID, filePath: filePath, line: line, column: column)
}
#endif
