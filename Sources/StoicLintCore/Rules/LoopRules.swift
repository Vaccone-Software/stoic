#if STOIC_LINT
import SwiftSyntax

/// A retry written as a loop: try, leave the loop on success, sleep in the
/// `catch`, go round again.
///
/// The loop is the retry that `retry` exists to replace. It retries
/// everything (defects and caller errors included), shares no budget with the
/// rest of the app, ignores the deadline, sleeps on the wall clock, and
/// reports nothing. It is matched as a loop (`for`, `while` or `repeat`)
/// whose body holds a `do` that `return`s or `break`s, with a `catch` that
/// sleeps. A loop that sleeps unconditionally (pacing) is not this shape.
final class HandRolledRetryRule: RuleVisitor {
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind { check(Syntax(node)); return .visitChildren }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { check(Syntax(node)); return .visitChildren }
    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { check(Syntax(node)); return .visitChildren }

    private func check(_ loop: Syntax) {
        guard let shape = LoopShape(loop), shape.backsOffInACatch, shape.leavesOnSuccess else { return }
        reporter.report(
            .handRolledRetry, at: shape.keyword,
            message:
                "This loop is a hand-rolled retry: it retries every error, ignores the deadline and any budget, sleeps on the wall clock and reports nothing.",
            fixIt: "use `retry(.exponential(base: …).attempts(n)) { attempt in … }`, which classifies, budgets and reports each attempt")
    }
}

/// A loop that keeps work alive forever: run it, and when it fails, sleep and
/// run it again.
///
/// A `Supervisor` is that loop with what it lacks: a restart policy, a limit
/// on how often restarting is allowed before it gives up loudly, heartbeats
/// for work that hangs instead of failing, and an owner that stops it. It is
/// matched as `while true`, `repeat { } while true`, or a loop on
/// `!Task.isCancelled`, whose body holds a `do` that does not leave on
/// success, with a `catch` that sleeps.
final class KeepAliveLoopRule: RuleVisitor {
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { check(Syntax(node)); return .visitChildren }
    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { check(Syntax(node)); return .visitChildren }

    private func check(_ loop: Syntax) {
        guard let shape = LoopShape(loop), shape.runsUntilCancelled, shape.backsOffInACatch, !shape.leavesOnSuccess
        else { return }
        reporter.report(
            .keepAliveLoop, at: shape.keyword,
            message:
                "This loop keeps work alive by catching and sleeping: it restarts forever, however often it fails, and nothing notices if it hangs.",
            fixIt:
                "run the work as a `Supervisor` child (restart policy, intensity limit, heartbeat), or as `recur` for periodic work")
    }
}

/// `group.addTask` once per element of a collection: as many concurrent tasks
/// as the collection has elements.
///
/// A thousand URLs become a thousand simultaneous requests, sockets and
/// buffers. Matched as `addTask` (or `addTaskUnlessCancelled`) directly in
/// the body of a `for … in <collection>`. Left alone: a loop over a numeric
/// range (`for _ in 0..<workers`, the bounded-workers pattern), a loop that
/// waits on `group.next()` (the sliding-window pattern), and `for await` over
/// an async sequence, whose size the linter cannot judge.
final class UnboundedTaskGroupRule: RuleVisitor {
    private static let adders: Set<String> = ["addTask", "addTaskUnlessCancelled"]

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let call = node.memberCall, Self.adders.contains(call.name),
            let loop = Self.enclosingLoop(of: node), loop.awaitKeyword == nil,
            !Self.isRange(loop.sequence), !LoopShape.waitsForAChild(loop.body),
            let member = node.calledExpression.as(MemberAccessExprSyntax.self)
        else { return .visitChildren }
        reporter.report(
            .unboundedTaskGroup, at: member.declName,
            message:
                "One child task per element runs the whole collection at once: memory, sockets and threads grow with the input.",
            fixIt: "use `mapConcurrent(elements, limit: n) { … }`, or wait on `group.next()` before adding past a limit")
        return .visitChildren
    }

    /// The `for` loop whose body the call sits in directly, not through a
    /// closure or function.
    private static func enclosingLoop(of node: some SyntaxProtocol) -> ForStmtSyntax? {
        var current = node.parent
        while let ancestor = current {
            if let loop = ancestor.as(ForStmtSyntax.self) { return loop }
            if ancestor.is(ClosureExprSyntax.self) || ancestor.is(FunctionDeclSyntax.self)
                || ancestor.is(WhileStmtSyntax.self) || ancestor.is(RepeatStmtSyntax.self)
            {
                return nil
            }
            current = ancestor.parent
        }
        return nil
    }

    /// `a..<b`, `a...b`, `stride(…)`, in parentheses or not.
    private static func isRange(_ expression: ExprSyntax) -> Bool {
        let expression = expression.strippingEffects
        if let sequence = expression.as(SequenceExprSyntax.self) {
            return sequence.elements.contains { element in
                guard let op = element.as(BinaryOperatorExprSyntax.self) else { return false }
                return op.operator.text == "..<" || op.operator.text == "..."
            }
        }
        if let infix = expression.as(InfixOperatorExprSyntax.self),
            let op = infix.operator.as(BinaryOperatorExprSyntax.self)
        {
            return op.operator.text == "..<" || op.operator.text == "..."
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return call.calledExpression.referencedName == "stride"
        }
        return false
    }
}

/// What the loop rules ask of a loop's body. Nested closures, functions and
/// loops are not searched: their effects are their own, and an inner loop is
/// judged on its own.
struct LoopShape {
    let keyword: TokenSyntax
    let body: CodeBlockSyntax
    let runsUntilCancelled: Bool
    private let doStatements: [DoStmtSyntax]

    init?(_ loop: Syntax) {
        if let loop = loop.as(ForStmtSyntax.self) {
            (keyword, body, runsUntilCancelled) = (loop.forKeyword, loop.body, false)
        } else if let loop = loop.as(WhileStmtSyntax.self) {
            let forever = loop.conditions.count == 1
                && loop.conditions.first.map { Self.isForever($0.condition) } == true
            (keyword, body, runsUntilCancelled) = (loop.whileKeyword, loop.body, forever)
        } else if let loop = loop.as(RepeatStmtSyntax.self) {
            (keyword, body, runsUntilCancelled) = (loop.repeatKeyword, loop.body, Self.isForever(loop.condition))
        } else {
            return nil
        }
        let finder = BodyFinder(viewMode: .sourceAccurate)
        finder.walk(body.statements)
        doStatements = finder.doStatements
    }

    /// Whether some `do` in the body has a `catch` that sleeps.
    var backsOffInACatch: Bool {
        doStatements.contains { $0.catchClauses.contains { Self.sleeps($0.body) } }
    }

    /// Whether some `do` that has a `catch` leaves the loop from its body:
    /// `return`, or a `break` that is not a `switch`'s.
    var leavesOnSuccess: Bool {
        doStatements.contains { statement in
            guard !statement.catchClauses.isEmpty else { return false }
            let finder = ExitOnSuccessFinder(viewMode: .sourceAccurate)
            finder.walk(statement.body.statements)
            return finder.found
        }
    }

    /// Whether the body calls `group.next()` or `group.waitForAll()`.
    static func waitsForAChild(_ body: CodeBlockSyntax) -> Bool {
        let finder = BodyFinder(viewMode: .sourceAccurate)
        finder.walk(body.statements)
        return finder.waitsForAChild
    }

    private static func sleeps(_ block: CodeBlockSyntax) -> Bool {
        let finder = BodyFinder(viewMode: .sourceAccurate)
        finder.walk(block.statements)
        return finder.sleeps
    }

    /// `true`, or anything that asks `isCancelled` (`!Task.isCancelled`).
    private static func isForever(_ condition: some SyntaxProtocol) -> Bool {
        if condition.trimmedDescription == "true" { return true }
        return condition.tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .identifier("isCancelled") }
    }
}

/// Collects a body's `do` statements, sleeps and child waits, without
/// entering nested closures, functions or loops.
private final class BodyFinder: SyntaxVisitor {
    private static let sleepers: Set<String> = ["sleep", "usleep"]
    var doStatements: [DoStmtSyntax] = []
    var sleeps = false
    var waitsForAChild = false

    override func visit(_ node: DoStmtSyntax) -> SyntaxVisitorContinueKind {
        doStatements.append(node)
        return .visitChildren
    }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.calledExpression.trailingName, Self.sleepers.contains(name) { sleeps = true }
        if let call = node.memberCall, call.name == "next" || call.name == "waitForAll" { waitsForAChild = true }
        return .visitChildren
    }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

/// A `return`, or a `break` that leaves the loop rather than a `switch`.
private final class ExitOnSuccessFinder: SyntaxVisitor {
    var found = false
    /// Inside a `switch`, an unlabeled `break` ends the `switch`, not the loop.
    private var switchDepth = 0

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind { found = true; return .skipChildren }
    override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind {
        if switchDepth == 0 || node.label != nil { found = true }
        return .skipChildren
    }
    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind { switchDepth += 1; return .visitChildren }
    override func visitPost(_ node: SwitchExprSyntax) { switchDepth -= 1 }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

#endif
