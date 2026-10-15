#if STOIC_LINT
import SwiftSyntax

/// `@unchecked Sendable`: the compiler's data-race check, switched off by
/// assertion. Sometimes right (a lock-protected box); never right silently.
final class UncheckedSendableRule: RuleVisitor {
    override func visit(_ node: AttributedTypeSyntax) -> SyntaxVisitorContinueKind {
        guard node.baseType.as(IdentifierTypeSyntax.self)?.name.text == "Sendable"
            || node.baseType.as(MemberTypeSyntax.self)?.name.text == "Sendable"
        else { return .visitChildren }
        for attribute in node.attributes {
            guard let attribute = attribute.as(AttributeSyntax.self),
                attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "unchecked"
            else { continue }
            reporter.report(
                .uncheckedSendable,
                at: attribute,
                message:
                    "`@unchecked Sendable` turns off the data-race check for this type and promises, unverified, that it is safe to share.",
                fixIt:
                    "make the type genuinely Sendable (a struct of Sendable values, an actor, or `Mutex`-guarded state), or justify it with `// stoic:allow(unchecked-sendable): <what makes it safe>`"
            )
        }
        return .visitChildren
    }
}

/// `nonisolated(unsafe)`: a global or stored property the compiler is told to
/// stop checking.
final class NonisolatedUnsafeRule: RuleVisitor {
    override func visit(_ node: DeclModifierSyntax) -> SyntaxVisitorContinueKind {
        if node.name.tokenKind == .keyword(.nonisolated), node.detail?.detail.text == "unsafe" {
            reporter.report(
                .nonisolatedUnsafe,
                at: node,
                message: "`nonisolated(unsafe)` exempts this declaration from data-race checking.",
                fixIt:
                    "guard the state with `Mutex` or an actor, or justify it with `// stoic:allow(nonisolated-unsafe): <what serializes access>`"
            )
        }
        return .visitChildren
    }
}

/// `Task.detached`: a task that inherits nothing. Task-locals (the ambient
/// context: clock, deadline, budgets, the cancellation cause) do not reach
/// it, so it quietly runs on the wall clock with no deadline.
final class TaskDetachedRule: RuleVisitor {
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == "detached", node.base?.referencedName == "Task" {
            reporter.report(
                .taskDetached,
                at: node,
                message:
                    "`Task.detached` drops task-locals: the ambient context, deadlines and cancellation causes do not reach the new task.",
                fixIt: "use `Task {}`, or a structured child (`withTaskGroup`, `withTaskScope`)"
            )
        }
        return .visitChildren
    }
}

/// `DispatchQueue…asyncAfter(`: a timer that nothing can cancel as part of a
/// scope, that ignores the deadline and cannot run on the test clock.
final class SleepForTimeoutRule: RuleVisitor {
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let call = node.memberCall, call.name == "asyncAfter",
            let member = node.calledExpression.as(MemberAccessExprSyntax.self)
        {
            reporter.report(
                .sleepForTimeout,
                at: member.declName,
                message:
                    "`asyncAfter` schedules a timer that no scope owns, no deadline bounds, and a test clock cannot advance.",
                fixIt: "use `withTimeout` to bound work, or `try await Ambient.sleep(for:)` inside a task the caller owns"
            )
        }
        return .visitChildren
    }
}

/// `@preconcurrency`: on an import, a conformance or a declaration, it
/// downgrades the Sendable and isolation errors the compiler would report
/// there to warnings, or to nothing. Sometimes it is the only way to use a
/// framework that predates strict concurrency; it is never right silently.
final class PreconcurrencyRule: RuleVisitor {
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if node.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "preconcurrency" {
            reporter.report(
                .preconcurrency,
                at: node,
                message:
                    "`@preconcurrency` silences the Sendable and isolation errors the compiler would report here.",
                fixIt:
                    "fix the isolation or Sendable gap, or justify it with `// stoic:allow(preconcurrency): <why the unchecked code is safe>`"
            )
        }
        return .visitChildren
    }
}

/// `Task.sleep` with no clock: a wait on the wall clock that a test cannot
/// advance, so a thirty-second backoff takes thirty seconds in CI.
///
/// Passing `clock:` is fine: the caller chose the clock, and a test can hand
/// it a test clock. Test code is exempt, since a test that needs real time
/// (an abandoned operation, a hang the runtime must notice) has to wait for
/// it.
final class BareTaskSleepRule: RuleVisitor {
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard !reporter.isTestFile, let call = node.memberCall, call.name == "sleep",
            call.base.referencedName == "Task", node.argument(labeled: "clock") == nil,
            let member = node.calledExpression.as(MemberAccessExprSyntax.self)
        else { return .visitChildren }
        reporter.report(
            .bareTaskSleep,
            at: member.declName,
            message: "`Task.sleep` waits on the wall clock: a test cannot advance it, and the ambient clock is ignored.",
            fixIt: "use `try await Ambient.sleep(for:)`, or pass the clock you were given (`clock.sleep(for:)`)"
        )
        return .visitChildren
    }
}

/// `AsyncStream` and `AsyncThrowingStream` with no buffer bound. The default
/// policy is `.unbounded`: a producer faster than its consumer grows memory
/// until the app is killed.
final class UnboundedStreamRule: RuleVisitor {
    private static let streams: Set<String> = ["AsyncStream", "AsyncThrowingStream"]

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard isStreamCreation(node.calledExpression) else { return .visitChildren }
        // `unfolding:` streams are pull-based: nothing is buffered.
        guard node.argument(labeled: "unfolding") == nil else { return .visitChildren }

        let fixIt =
            "use `Channel(capacity:overflow:)` for a queue with a stated overflow, or pass `bufferingPolicy: .bufferingNewest(n)`"
        if let policy = node.argument(labeled: "bufferingPolicy") {
            if policy.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "unbounded" {
                reporter.report(
                    .unboundedStream, at: policy,
                    message: "`bufferingPolicy: .unbounded` lets a fast producer grow memory without limit.",
                    fixIt: fixIt)
            }
        } else {
            reporter.report(
                .unboundedStream, at: node,
                message: "A stream created without `bufferingPolicy:` is unbounded by default.",
                fixIt: fixIt)
        }
        return .visitChildren
    }

    /// `AsyncStream(…)`, `AsyncStream<T>(…)`, `AsyncStream<T>.init(…)` and
    /// `AsyncStream<T>.makeStream(…)`.
    private func isStreamCreation(_ callee: ExprSyntax) -> Bool {
        if let name = callee.referencedName { return Self.streams.contains(name) }
        if let member = callee.as(MemberAccessExprSyntax.self), let base = member.base,
            let name = base.referencedName, Self.streams.contains(name)
        {
            return ["init", "makeStream"].contains(member.declName.baseName.text)
        }
        return false
    }
}

#endif
