#if STOIC_MACROS
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// A diagnostic's identity and words. The `id` is stable (tests and
/// suppressions can name it); the message is what a person reads.
struct Problem {
    var id: String
    var message: String
}

struct Message: DiagnosticMessage {
    var problem: Problem
    var severity: DiagnosticSeverity
    var message: String { problem.message }
    var diagnosticID: MessageID { MessageID(domain: "StoicMacros", id: problem.id) }
}

struct Fix: FixItMessage {
    var message: String
    var fixItID: MessageID { MessageID(domain: "StoicMacros", id: "fix") }
}

/// Collects what a macro has to say about the code it was attached to, and
/// remembers whether any of it was an error: a macro that has reported an
/// error expands to nothing, so the person sees the diagnostics and not the
/// pile of follow-on errors that half a schema would cause.
final class Reporter {
    let context: any MacroExpansionContext
    private(set) var errorCount = 0
    /// A silent reporter counts errors and says nothing, for a second pass
    /// over a declaration whose errors have already been reported.
    let isSilent: Bool

    init(_ context: any MacroExpansionContext, silent: Bool = false) {
        self.context = context
        isSilent = silent
    }

    var hasErrors: Bool { errorCount > 0 }

    func error(
        _ node: some SyntaxProtocol, _ problem: Problem, fixIts: [FixIt] = []
    ) {
        errorCount += 1
        if isSilent { return }
        context.diagnose(Diagnostic(node: Syntax(node), message: Message(problem: problem, severity: .error), fixIts: fixIts))
    }

    func warning(
        _ node: some SyntaxProtocol, _ problem: Problem, fixIts: [FixIt] = []
    ) {
        if isSilent { return }
        context.diagnose(Diagnostic(node: Syntax(node), message: Message(problem: problem, severity: .warning), fixIts: fixIts))
    }
}

extension FixIt {
    /// Replaces `node` with `text`.
    static func replacing(_ node: some SyntaxProtocol, with text: String, _ message: String) -> FixIt {
        FixIt(
            message: Fix(message: message),
            changes: [.replace(oldNode: Syntax(node), newNode: Syntax(fromProtocol: TokenSyntax.identifier(text).with(\.leadingTrivia, node.leadingTrivia).with(\.trailingTrivia, node.trailingTrivia)))])
    }

    /// Inserts `text` just after `node`.
    static func inserting(_ text: String, after node: some SyntaxProtocol, _ message: String) -> FixIt {
        FixIt(
            message: Fix(message: message),
            changes: [.replaceText(range: node.endPositionBeforeTrailingTrivia..<node.endPositionBeforeTrailingTrivia, with: text, in: Syntax(node))])
    }

    /// Inserts `text` just before `node`.
    static func inserting(_ text: String, before node: some SyntaxProtocol, _ message: String) -> FixIt {
        let start = node.positionAfterSkippingLeadingTrivia
        return FixIt(
            message: Fix(message: message),
            changes: [.replaceText(range: start..<start, with: text, in: Syntax(node))])
    }

    /// Removes `node`.
    static func removing(_ node: some SyntaxProtocol, _ message: String) -> FixIt {
        // The attribute's own space goes with it, so no double space is left.
        let empty = TokenSyntax.identifier("").with(\.leadingTrivia, node.leadingTrivia)
        return FixIt(
            message: Fix(message: message),
            changes: [.replace(oldNode: Syntax(node), newNode: Syntax(fromProtocol: empty))])
    }
}
#endif
