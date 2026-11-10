#if STOIC_LINT
import SwiftSyntax

/// An error's `localizedDescription` read outside test code: how raw error
/// text reaches a person (design/31).
///
/// The text is whatever the error's author wrote, or whatever Foundation
/// assembled from a failure: it can hold an email address, a token, a path
/// with a user name in it, and it says nothing a person can act on.
/// `error.presented()` gives the words and the recovery instead, with a
/// reference support can match to the event that holds the text, privately.
///
/// Exempt: test code, and `Sources/StoicFoundation`, the one place Stoic meets
/// Foundation's errors. Syntactic, as every rule is: `"\(error)"` in a view
/// and `String(describing: error)` are not seen.
final class ErrorTextShownRule: RuleVisitor {
    private static let seamDirectory = "/Sources/StoicFoundation/"

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard !reporter.isTestFile, !("/" + reporter.path).contains(Self.seamDirectory),
            node.declName.baseName.text == "localizedDescription", node.declName.argumentNames == nil,
            // A method of the app's own that shares the name is not the property.
            node.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id != Syntax(node).id
        else { return .visitChildren }
        reporter.report(
            .errorTextShown, at: node.declName,
            message: "`localizedDescription` is an error's raw text: it can hold private data, and it tells a person nothing they can act on.",
            fixIt: "present it with `error.presented()`: the words, what to do, and a reference that support can match to the event")
        return .visitChildren
    }
}

#endif
