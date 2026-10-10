#if STOIC_LINT
import SwiftSyntax

/// Blocking a thread inside async code.
///
/// Swift's cooperative pool has about one thread per core. A task that parks
/// its thread in `semaphore.wait()` or `sleep(1)` takes a core's worth of the
/// pool with it, and work that could wake it may be queued behind it: the
/// process stalls, or deadlocks under load. None of these calls can be
/// cancelled, bounded by a deadline, or run on a test clock either.
///
/// "Inside async code" is decided syntactically. A body is async when it is:
///
/// - an `async` function, initializer or accessor;
/// - a method (or computed property) of an `actor`, which blocks the actor's
///   executor even when it is synchronous (`nonisolated` members are exempt);
/// - a closure marked `async`, or passed to something that runs it as a task
///   (`Task { }`, `addTask { }`, `withTaskGroup`, `MainActor.run`, and
///   Stoic's own `withTimeout`, `retry`, `withScope`, …).
///
/// Any other closure is treated as synchronous, even inside an async
/// function. That misses `array.map { sleep(1) }` in an async function, and
/// it is deliberate: `DispatchQueue.global().async { semaphore.wait() }`
/// blocks a Dispatch thread, not the cooperative pool, and is the sanctioned
/// way to bridge blocking code. The rule must not call the bridge a bug.
final class BlockingInAsyncRule: RuleVisitor {
    private enum Scope {
        /// A type body; `actor` marks an actor.
        case type(actor: Bool)
        /// A function, initializer, accessor or closure body.
        case body(async: Bool)
    }

    private var scopes: [Scope] = []
    /// Closures known to run as async work, collected as their calls are
    /// visited (a call is always visited before its closures).
    private var asyncClosures: Set<SyntaxIdentifier> = []

    /// Free functions and initializers whose closure argument runs as a task.
    private static let asyncBodyCallees: Set<String> = [
        "Task", "withTaskGroup", "withThrowingTaskGroup", "withDiscardingTaskGroup",
        "withThrowingDiscardingTaskGroup", "withTimeout", "withDeadline", "retry", "recur",
        "withScope", "withTaskScope", "race", "hedge", "mapConcurrent", "withContext",
    ]
    /// Member calls (`group.addTask { }`, `Task.detached { }`) likewise.
    private static let asyncBodyMembers: Set<String> = [
        "addTask", "addTaskUnlessCancelled", "detached", "immediate", "withPermit",
    ]

    private var inAsyncBody: Bool {
        for scope in scopes.reversed() {
            if case .body(let isAsync) = scope { return isAsync }
        }
        return false
    }

    private var directlyInActor: Bool {
        if case .type(let isActor)? = scopes.last { return isActor }
        return false
    }

    // MARK: Scopes

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(.type(actor: true))
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { scopes.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(.type(actor: false))
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { scopes.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(.type(actor: false))
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { scopes.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(.type(actor: false))
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { scopes.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(.type(actor: false))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { scopes.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let isAsync =
            node.signature.effectSpecifiers?.asyncSpecifier != nil
            || (directlyInActor && isActorIsolated(node.modifiers))
        scopes.append(.body(async: isAsync))
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { scopes.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let isAsync =
            node.signature.effectSpecifiers?.asyncSpecifier != nil
            || (directlyInActor && isActorIsolated(node.modifiers))
        scopes.append(.body(async: isAsync))
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { scopes.removeLast() }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append(.body(async: false))
        return .visitChildren
    }
    override func visitPost(_ node: DeinitializerDeclSyntax) { scopes.removeLast() }

    /// A computed property's accessors. Stored-property initializers run in
    /// the same place, which is harmless: nothing there blocks.
    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        var isAsync = false
        if directlyInActor, let variable = node.parent?.parent?.parent?.as(VariableDeclSyntax.self) {
            isAsync = isActorIsolated(variable.modifiers)
        }
        if case .accessors(let accessors) = node.accessors,
            accessors.contains(where: { $0.effectSpecifiers?.asyncSpecifier != nil })
        {
            isAsync = true
        }
        scopes.append(.body(async: isAsync))
        return .visitChildren
    }
    override func visitPost(_ node: AccessorBlockSyntax) { scopes.removeLast() }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        let isAsync =
            node.signature?.effectSpecifiers?.asyncSpecifier != nil || asyncClosures.contains(node.id)
        scopes.append(.body(async: isAsync))
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { scopes.removeLast() }

    /// A member of an actor is isolated to it unless `nonisolated` or
    /// `static`.
    private func isActorIsolated(_ modifiers: DeclModifierListSyntax) -> Bool {
        !modifiers.contains(.nonisolated) && !modifiers.contains(.static) && !modifiers.contains(.class)
    }

    // MARK: Calls

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        markAsyncClosures(of: node)
        guard inAsyncBody else { return .visitChildren }

        if let call = node.memberCall {
            checkMember(call.base, call.name, node)
        } else if let name = node.calledExpression.referencedName, node.calledExpression.is(DeclReferenceExprSyntax.self) {
            checkFreeFunction(name, node)
        }
        return .visitChildren
    }

    private func markAsyncClosures(of call: FunctionCallExprSyntax) {
        let runsAsTask: Bool
        if let member = call.memberCall {
            if member.name == "run" {
                runsAsTask = member.base.referencedName == "MainActor"
            } else {
                runsAsTask = Self.asyncBodyMembers.contains(member.name)
            }
        } else if let name = call.calledExpression.referencedName {
            runsAsTask = Self.asyncBodyCallees.contains(name)
        } else {
            runsAsTask = false
        }
        if runsAsTask {
            for closure in call.closures { asyncClosures.insert(closure.id) }
        }
    }

    private func checkFreeFunction(_ name: String, _ call: FunctionCallExprSyntax) {
        // The C functions take one unlabeled argument; `sleep(for:)` and
        // friends are somebody's async API.
        guard name == "sleep" || name == "usleep", call.arguments.count == 1,
            call.arguments.first?.label == nil
        else { return }
        reporter.report(
            .blockingInAsync, at: call,
            message:
                "`\(name)` blocks a thread of the cooperative pool inside async code, and cannot be cancelled or run on a test clock.",
            fixIt: "use `try await Ambient.sleep(for:)`")
    }

    private func checkMember(_ base: ExprSyntax, _ name: String, _ call: FunctionCallExprSyntax) {
        switch name {
        case "wait":
            guard Self.looksLikeBlockingWaiter(base), Self.hasWaitArguments(call) else { return }
            reporter.report(
                .blockingInAsync, at: call,
                message:
                    "`wait()` parks a thread of the cooperative pool inside async code; under load that starves or deadlocks the pool.",
                fixIt: "use `AsyncSemaphore` / `AsyncMutex`, or `await` the work directly")
        case "sleep", "usleep":
            if name == "sleep", base.referencedName == "Thread" || base.trailingName == "Thread" {
                reporter.report(
                    .blockingInAsync, at: call,
                    message:
                        "`Thread.sleep` blocks a thread of the cooperative pool inside async code, and cannot be cancelled or run on a test clock.",
                    fixIt: "use `try await Ambient.sleep(for:)`")
            } else if let module = base.referencedName, ["Darwin", "Glibc", "Musl", "Foundation"].contains(module) {
                checkFreeFunction(name, call)
            }
        case "sync":
            guard call.arguments.allSatisfy({ ["execute", "flags", nil].contains($0.label?.text) }),
                call.hasClosure || call.argument(labeled: "execute") != nil,
                base.trimmedDescription.lowercased().contains("queue")
            else { return }
            reporter.report(
                .blockingInAsync, at: call,
                message:
                    "`DispatchQueue.sync` blocks a thread of the cooperative pool until the queue gets to the work, and deadlocks if the queue is waiting on this task.",
                fixIt: "make the work `async` and `await` it, or hop with an actor or `@MainActor`")
        default:
            return
        }
    }

    /// `wait()` and `wait(timeout:)`/`wait(wallTimeout:)`: the Dispatch
    /// shapes. Other `wait` methods (`Process.waitUntilExit`, condition
    /// variables) have other names or other arguments.
    private static func hasWaitArguments(_ call: FunctionCallExprSyntax) -> Bool {
        guard let first = call.arguments.first else { return true }
        return call.arguments.count == 1 && ["timeout", "wallTimeout"].contains(first.label?.text)
    }

    /// Whether a receiver reads like a `DispatchSemaphore` or
    /// `DispatchGroup`: `semaphore`, `sem`, `readySemaphore`, `group`,
    /// `dispatchGroup`, `DispatchSemaphore(value: 0)`.
    private static func looksLikeBlockingWaiter(_ base: ExprSyntax) -> Bool {
        guard let name = base.trailingName?.lowercased() else { return false }
        return name.contains("semaphore") || name.contains("sema") || name == "sem" || name.hasSuffix("sem")
            || name.contains("group")
    }
}

#endif
