#if STOIC_LINT
import SwiftSyntax

/// `try?` used as a statement: the error is thrown away and so is the fact
/// that anything went wrong.
///
/// Only a _discarded_ result is flagged. `let x = try? f()`, `return try? f()`
/// and `if let x = try? f()` use the result: the author chose "nil means it
/// failed" and the type system makes them look at it. A statement-level
/// `try? f()` and `_ = try? f()` look at nothing.
///
/// A body whose single expression is `try? f()` (a closure, a function with
/// an implicit return) returns the value, so it is not discarded, with one
/// exception: the body of a `Task { }` that is itself a statement, because
/// nobody can read that task's result.
final class DiscardedTryRule: RuleVisitor {
    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        guard let tried = discardedOptionalTry(in: node) else { return .visitChildren }
        reporter.report(
            .discardedTry, at: tried,
            message:
                "`try?` discards the error: nothing records that this failed, why, or what the code was doing.",
            fixIt:
                "handle the error, or keep its story with `withContext(\"what I was doing\") { … }` and let it propagate")
        return .visitChildren
    }

    private func discardedOptionalTry(in item: CodeBlockItemSyntax) -> TryExprSyntax? {
        guard case .expr(let expression) = item.item else { return nil }

        // `_ = try? f()`: assigning to the wildcard throws the value away
        // wherever the statement sits.
        if let sequence = expression.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            guard elements.count == 3, elements[0].is(DiscardAssignmentExprSyntax.self),
                elements[1].is(AssignmentExprSyntax.self)
            else { return nil }
            return Self.optionalTry(elements[2])
        }

        guard let tried = Self.optionalTry(expression) else { return nil }
        return Self.isValueOfEnclosingBody(item) ? nil : tried
    }

    /// `try? …` (through a leading `await`), or nil.
    private static func optionalTry(_ expression: ExprSyntax) -> TryExprSyntax? {
        if let awaited = expression.as(AwaitExprSyntax.self) { return optionalTry(awaited.expression) }
        guard let tried = expression.as(TryExprSyntax.self),
            tried.questionOrExclamationMark?.tokenKind == .postfixQuestionMark
        else { return nil }
        return tried
    }

    /// Whether `item`, a lone expression statement, supplies the value of
    /// the closure, function, accessor, `if` or `switch` around it.
    private static func isValueOfEnclosingBody(_ item: CodeBlockItemSyntax) -> Bool {
        guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
            let owner = list.parent
        else { return false }

        if let closure = owner.as(ClosureExprSyntax.self) {
            return !Self.isStatementTask(closure)
        }
        if owner.is(AccessorBlockSyntax.self) { return true }  // `var x: Int? { try? f() }`
        if let switchCase = owner.as(SwitchCaseSyntax.self) {
            guard let switchExpr = switchCase.parent?.parent?.as(SwitchExprSyntax.self) else { return false }
            return Self.isUsedAsValue(ExprSyntax(switchExpr))
        }
        guard let block = owner.as(CodeBlockSyntax.self), let parent = block.parent else { return false }
        // A body returns its lone expression only if it has something to return.
        if let function = parent.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause.map { !Self.isVoid($0.type) } ?? false
        }
        if let accessor = parent.as(AccessorDeclSyntax.self) { return accessor.accessorSpecifier.tokenKind == .keyword(.get) }
        if let ifExpr = parent.as(IfExprSyntax.self) { return Self.isUsedAsValue(ExprSyntax(ifExpr)) }
        return false  // do, for, while, defer, guard-else, init, deinit: statements all
    }

    private static func isVoid(_ type: TypeSyntax) -> Bool {
        type.trimmedDescription == "Void" || type.trimmedDescription == "()"
    }

    /// Whether an `if`/`switch` expression's value is used, looking through
    /// `else if` chains to the outermost.
    private static func isUsedAsValue(_ expression: ExprSyntax) -> Bool {
        var current = Syntax(expression)
        while let parent = current.parent, parent.is(IfExprSyntax.self) { current = parent }
        guard var parent = current.parent else { return false }
        // A statement-position `if` or `switch` is wrapped in an expression statement.
        if parent.is(ExpressionStmtSyntax.self), let wrapper = parent.parent { parent = wrapper }
        guard let item = parent.as(CodeBlockItemSyntax.self) else { return true }  // initializer, return, argument…
        // A statement-level `if`: its value is the enclosing body's only when
        // it is that body's one statement.
        return isValueOfEnclosingBody(item)
    }

    /// `Task { try? await f() }` as a statement, which nobody can read.
    private static func isStatementTask(_ closure: ClosureExprSyntax) -> Bool {
        guard let call = closure.parent?.as(FunctionCallExprSyntax.self) else { return false }
        let isTask =
            call.calledExpression.referencedName == "Task"
            || (call.memberCall.map { $0.base.referencedName == "Task" && $0.name == "detached" } ?? false)
        guard isTask else { return false }
        return call.parent?.is(CodeBlockItemSyntax.self) == true
    }
}

/// `try!` outside tests: a crash with no message as the failure handler.
///
/// Exempt: a regex built from a string literal (`try! Regex("[a-z]+")`),
/// which fails every time or never, the first time it runs; and anything in
/// test code (a path under `/Tests/` or a file named `…Tests.swift`), where
/// a crash is a failing test.
final class ForceTryRule: RuleVisitor {
    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.questionOrExclamationMark?.tokenKind == .exclamationMark,
            !reporter.isTestFile, !Self.isLiteralRegex(node.expression)
        else { return .visitChildren }
        reporter.report(
            .forceTry, at: node,
            message: "`try!` crashes the process on any error, with no context about what failed.",
            fixIt:
                "propagate with `try`, or handle the error; if it truly cannot fail, say why with `// stoic:allow(force-try): <why>`")
        return .visitChildren
    }

    /// `Regex("literal")` and `NSRegularExpression(pattern: "literal")`: the
    /// pattern is a constant, so the `try!` is a compile-time-ish assertion.
    private static func isLiteralRegex(_ expression: ExprSyntax) -> Bool {
        guard let call = expression.strippingEffects.as(FunctionCallExprSyntax.self),
            let name = call.calledExpression.referencedName
        else { return false }
        let pattern: ExprSyntax?
        switch name {
        case "Regex": pattern = call.arguments.first?.expression
        case "NSRegularExpression": pattern = call.argument(labeled: "pattern")
        default: return false
        }
        guard let literal = pattern?.as(StringLiteralExprSyntax.self) else { return false }
        return literal.segments.allSatisfy { $0.is(StringSegmentSyntax.self) }
    }
}

#endif
