#if STOIC_LINT
import SwiftSyntax

/// The shapes the rules keep asking about. Kept apart so a rule reads as the
/// pattern it flags rather than as tree navigation.
extension ExprSyntax {
    /// The type or function name an expression refers to, looking through a
    /// generic argument list: `AsyncStream<Int>` and `AsyncStream` are both
    /// "AsyncStream". Nil for anything that is not a plain reference.
    var referencedName: String? {
        if let reference = self.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let specialized = self.as(GenericSpecializationExprSyntax.self) {
            return specialized.expression.referencedName
        }
        return nil
    }

    /// The identifier at the end of the expression, which is what a reader
    /// takes the receiver to be called: `self.requests.group` is "group",
    /// `DispatchSemaphore(value: 0)` is "DispatchSemaphore".
    var trailingName: String? {
        if let reference = self.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
        if let member = self.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        if let call = self.as(FunctionCallExprSyntax.self) { return call.calledExpression.trailingName }
        if let specialized = self.as(GenericSpecializationExprSyntax.self) { return specialized.expression.trailingName }
        if let force = self.as(ForceUnwrapExprSyntax.self) { return force.expression.trailingName }
        if let chained = self.as(OptionalChainingExprSyntax.self) { return chained.expression.trailingName }
        if let tuple = self.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return only.expression.trailingName
        }
        return nil
    }

    /// The expression with `await`, `try` and parentheses peeled off.
    var strippingEffects: ExprSyntax {
        if let awaited = self.as(AwaitExprSyntax.self) { return awaited.expression.strippingEffects }
        if let tried = self.as(TryExprSyntax.self) { return tried.expression.strippingEffects }
        if let tuple = self.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first,
            only.label == nil
        {
            return only.expression.strippingEffects
        }
        return self
    }
}

extension FunctionCallExprSyntax {
    /// For `base.name(…)`: the base and the member name. Nil when the callee
    /// is not a member access, or has no base (`.name(…)`).
    var memberCall: (base: ExprSyntax, name: String)? {
        guard let member = calledExpression.as(MemberAccessExprSyntax.self), let base = member.base else {
            return nil
        }
        return (base, member.declName.baseName.text)
    }

    /// The value passed for `label:`.
    func argument(labeled label: String) -> ExprSyntax? {
        arguments.first { $0.label?.text == label }?.expression
    }

    /// Every closure passed to the call, as an argument or trailing.
    var closures: [ClosureExprSyntax] {
        var result = arguments.compactMap { $0.expression.as(ClosureExprSyntax.self) }
        if let trailingClosure { result.append(trailingClosure) }
        result += additionalTrailingClosures.map(\.closure)
        return result
    }

    var hasClosure: Bool { trailingClosure != nil || !closures.isEmpty }
}

extension DeclModifierListSyntax {
    func contains(_ keyword: Keyword) -> Bool {
        contains { $0.name.tokenKind == .keyword(keyword) }
    }
}

#endif
