#if STOIC_LINT
import SwiftSyntax

/// `IdempotencyKey.random()` inside a `retry` operation: a new key for every
/// attempt, which is no key at all.
///
/// An idempotency key exists so a server recognises a retried request as the
/// one it already handled. Drawn inside the operation, each attempt sends a
/// different key, and an attempt whose response was lost is performed again
/// by the next: the double charge the key was meant to prevent.
///
/// The key is matched as `IdempotencyKey.random(…)`, anywhere inside a
/// closure passed to `retry(…)`, nested closures included. A key built from a
/// stable value (`IdempotencyKey(rawValue: order.id)`) is the same on every
/// attempt and is not flagged. Not seen: a key drawn through an inferred
/// `.random()`, or inside `Retrying(…).execute { }` or a pipeline, whose
/// retrying the linter cannot see.
final class KeyInsideRetryRule: RuleVisitor {
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let call = node.memberCall, call.name == "random", call.base.referencedName == "IdempotencyKey",
            Self.isInsideRetryOperation(node)
        else { return .visitChildren }
        reporter.report(
            .keyInsideRetry, at: node,
            message:
                "A key drawn inside the retried operation is new on every attempt, so the server cannot recognise a retry as the same request.",
            fixIt:
                "use `attempt.idempotencyKey`, which is the same on every attempt, or draw the key before `retry` and capture it")
        return .visitChildren
    }

    /// Whether `node` sits inside a closure passed to a call named `retry`.
    private static func isInsideRetryOperation(_ node: some SyntaxProtocol) -> Bool {
        var closure: ClosureExprSyntax?
        var current = node.parent
        while let ancestor = current {
            if let found = ancestor.as(ClosureExprSyntax.self) {
                closure = found
            } else if let enclosing = closure, let call = ancestor.as(FunctionCallExprSyntax.self),
                call.calledExpression.trailingName == "retry",
                call.closures.contains(where: { $0.id == enclosing.id })
            {
                return true
            }
            current = ancestor.parent
        }
        return false
    }
}

#endif
