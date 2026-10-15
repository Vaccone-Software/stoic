#if STOIC_LINT
import SwiftSyntax

/// A `catch` that matches `CancellationError` and then carries on.
///
/// Cancellation is the owner of a task saying "stop". A clause that catches
/// it and falls through (or `continue`s) keeps the work running after its
/// owner asked it to end, and hides from everything above it that the work
/// was cancelled: a loop that should have stopped spins on, and a scope
/// waiting for its children waits.
///
/// A catch-all counts as matching cancellation when every `try` in its `do`
/// is a sleep (`clock.sleep(…)`, `Ambient.sleep(…)`), since a sleep throws
/// nothing else: `while true { do { try await sleep() } catch {}; poll() }`
/// spins forever once cancelled.
///
/// A clause is fine when it leaves: it rethrows, throws something else,
/// `return`s, `break`s, or calls `fatalError` and its kin. Falling through is
/// also fine when it ends a function, closure or accessor body (the `do` is
/// the body's last statement, or the last of an `if`, `switch` or `do` that
/// is itself last), because falling off the end of a body is returning. A
/// loop in between is not the end: its next turn runs.
///
/// Test code is exempt: a test catches cancellation to assert that it
/// happened.
final class SwallowedCancellationRule: RuleVisitor {
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        guard !reporter.isTestFile, node.matchesCancellation, !node.body.leaves,
            !node.fallsOffTheEndOfABody
        else { return .visitChildren }
        reporter.report(
            .swallowedCancellation, at: node.catchKeyword,
            message:
                "This `catch` swallows cancellation: the work carries on after its owner asked it to stop, and nothing above it learns it was cancelled.",
            fixIt:
                "let `CancellationError` propagate (rethrow it, or remove the clause); to stop quietly, `return` instead of carrying on")
        return .visitChildren
    }
}

/// A catch-all whose body does nothing with the error, or only prints it.
///
/// `catch {}` and `catch { print(error) }` are `try?` written longhand: the
/// failure, its cause and what the code was doing vanish (print output goes
/// nowhere in a shipped app). Only clauses that catch _everything_ are
/// flagged, either with no pattern or with a bare `let error`: a clause that
/// names an error (`catch CocoaError.fileNoSuchFile {}`) is the author saying
/// which failure is expected, and that is handling it.
///
/// Two catch-alls are not swallowing, and are left alone. One whose `do` only
/// sleeps catches cancellation, not failure: that is `swallowed-cancellation`'s
/// business. One nested in another `catch` that goes on to `throw` is a
/// secondary failure (closing a file while reporting why the read failed):
/// the original error still propagates, and it is the one worth reporting.
///
/// "Only prints" means every statement is a call to `print`, `debugPrint`,
/// `dump` or `NSLog`. A clause that logs through `Logger` or records an event
/// has chosen where the error goes, and is left alone.
///
/// Test code is exempt, as for `discarded-try`: tests routinely discard the
/// error of work they have just torn down.
final class SwallowedErrorRule: RuleVisitor {
    private static let printers: Set<String> = ["print", "debugPrint", "dump", "NSLog"]

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        guard !reporter.isTestFile, node.catchesEverything, !node.onlySleepsThrow, !node.isSecondaryToARethrow
        else { return .visitChildren }
        let statements = node.body.statements
        let message: String
        if statements.isEmpty {
            message = "This `catch` discards every error: nothing records that the work failed, why, or what it was doing."
        } else if statements.allSatisfy(Self.isPrint) {
            message = "This `catch` only prints the error, which goes nowhere in a shipped app; the failure is otherwise discarded."
        } else {
            return .visitChildren
        }
        reporter.report(
            .swallowedError, at: node.catchKeyword,
            message: message,
            fixIt:
                "handle the error, or let it propagate with `withContext(\"what I was doing\") { … }`; if ignoring it is right, say why with `// stoic:allow(swallowed-error): <why>`")
        return .visitChildren
    }

    private static func isPrint(_ item: CodeBlockItemSyntax) -> Bool {
        guard case .expr(let expression) = item.item,
            let call = expression.strippingEffects.as(FunctionCallExprSyntax.self),
            let name = call.calledExpression.referencedName
        else { return false }
        return printers.contains(name)
    }
}

extension CatchClauseSyntax {
    /// Whether any of the clause's patterns names `CancellationError`:
    /// `catch is CancellationError`, `catch let e as CancellationError`,
    /// `catch _ as CancellationError`.
    /// A catch-all over a `do` that only sleeps counts too.
    fileprivate var matchesCancellation: Bool {
        let named = catchItems.contains { item in
            item.pattern?.tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .identifier("CancellationError") }
                ?? false
        }
        return named || (catchesEverything && onlySleepsThrow)
    }

    /// The `do` statement this clause belongs to.
    private var doStatement: DoStmtSyntax? { parent?.parent?.as(DoStmtSyntax.self) }

    /// Whether the only things that can throw in the `do` are sleeps, which
    /// throw nothing but `CancellationError`: there is at least one `try`,
    /// every `try` is a call to something named `sleep`, and nothing `throw`s.
    fileprivate var onlySleepsThrow: Bool {
        guard let body = doStatement?.body else { return false }
        let finder = EffectFinder(viewMode: .sourceAccurate)
        finder.walk(body.statements)
        return !finder.tries.isEmpty && !finder.hasThrow
            && finder.tries.allSatisfy { tried in
                tried.expression.strippingEffects.as(FunctionCallExprSyntax.self)?.calledExpression.trailingName == "sleep"
            }
    }

    /// Whether this clause sits inside another `catch` clause, in the same
    /// function or closure, whose body `throw`s.
    fileprivate var isSecondaryToARethrow: Bool {
        var current = parent
        while let ancestor = current {
            if ancestor.is(ClosureExprSyntax.self) || ancestor.is(FunctionDeclSyntax.self) { return false }
            if let outer = ancestor.as(CatchClauseSyntax.self) {
                let finder = EffectFinder(viewMode: .sourceAccurate)
                finder.walk(outer.body.statements)
                return finder.hasThrow
            }
            current = ancestor.parent
        }
        return false
    }

    /// `catch`, `catch let error`, `catch var e`, `catch _`, with no `where`.
    fileprivate var catchesEverything: Bool {
        if catchItems.isEmpty { return true }
        guard catchItems.count == 1, let item = catchItems.first, item.whereClause == nil,
            let pattern = item.pattern
        else { return false }
        if pattern.is(WildcardPatternSyntax.self)
            || pattern.as(ExpressionPatternSyntax.self)?.expression.is(DiscardAssignmentExprSyntax.self) == true
        {
            return true
        }
        guard let binding = pattern.as(ValueBindingPatternSyntax.self) else { return false }
        return binding.pattern.is(IdentifierPatternSyntax.self) || binding.pattern.is(WildcardPatternSyntax.self)
    }

    /// Whether falling through the clause ends a function, initializer,
    /// accessor or closure body: the `do` is the body's last statement, or
    /// the last statement of an `if`, `switch`, `do` or `catch` that is
    /// itself last, and so on outwards. A loop in between means the next
    /// turn runs, so it is not the end.
    fileprivate var fallsOffTheEndOfABody: Bool {
        guard let doStmt = doStatement else { return false }
        return Self.endsItsBody(Syntax(doStmt))
    }

    private static func endsItsBody(_ statement: Syntax) -> Bool {
        var statement = statement
        if let wrapper = statement.parent, wrapper.is(ExpressionStmtSyntax.self) { statement = wrapper }
        guard let item = statement.parent?.as(CodeBlockItemSyntax.self),
            let list = item.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == item.id,
            let owner = list.parent
        else { return false }
        if owner.is(ClosureExprSyntax.self) || owner.is(AccessorBlockSyntax.self) { return true }
        if owner.is(SwitchCaseSyntax.self), let switchExpr = owner.parent?.parent, switchExpr.is(SwitchExprSyntax.self) {
            return endsItsBody(switchExpr)
        }
        guard let block = owner.as(CodeBlockSyntax.self), let construct = block.parent else { return false }
        if construct.is(FunctionDeclSyntax.self) || construct.is(InitializerDeclSyntax.self)
            || construct.is(AccessorDeclSyntax.self) || construct.is(DeinitializerDeclSyntax.self)
        {
            return true
        }
        if construct.is(IfExprSyntax.self) {
            // An `else if` is nested in the `if` before it; the chain ends
            // where the outermost `if` does.
            var outermost = construct
            while let parent = outermost.parent, parent.is(IfExprSyntax.self) { outermost = parent }
            return endsItsBody(outermost)
        }
        if construct.is(DoStmtSyntax.self) { return endsItsBody(construct) }
        if construct.is(CatchClauseSyntax.self), let outerDo = construct.parent?.parent, outerDo.is(DoStmtSyntax.self) {
            return endsItsBody(outerDo)
        }
        return false  // for, while, repeat (the next turn runs), guard-else, defer
    }
}

extension CodeBlockSyntax {
    /// Whether the block contains a statement that leaves it: `throw`,
    /// `return`, `break`, or a call that never returns. Nested closures and
    /// functions are not searched, since their exits are their own.
    fileprivate var leaves: Bool {
        let finder = ExitFinder(viewMode: .sourceAccurate)
        finder.walk(statements)
        return finder.found
    }
}

private final class ExitFinder: SyntaxVisitor {
    private static let neverReturning: Set<String> = ["fatalError", "preconditionFailure", "exit", "abort"]
    var found = false

    override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
    override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.calledExpression.referencedName, Self.neverReturning.contains(name) { found = true }
        return .visitChildren
    }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

/// The `try`s and `throw`s of a block, not counting nested closures and
/// functions, whose effects are their own. A nested `do` is searched too:
/// what it does not catch reaches the outer one, and a syntactic linter
/// cannot tell what it catches.
private final class EffectFinder: SyntaxVisitor {
    var tries: [TryExprSyntax] = []
    var hasThrow = false

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        // `try?` and `try!` keep their errors to themselves.
        if node.questionOrExclamationMark == nil { tries.append(node) }
        return .visitChildren
    }
    override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind { hasThrow = true; return .visitChildren }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

#endif
