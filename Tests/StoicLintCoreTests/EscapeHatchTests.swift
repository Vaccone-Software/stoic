#if STOIC_LINT
import StoicLintCore
import Testing

@Suite("unchecked-sendable")
struct UncheckedSendableTests {
    @Test func flagsAClassConformance() {
        #expect(rules(in: "final class Box: @unchecked Sendable {}\n") == ["unchecked-sendable"])
    }

    @Test func flagsAnExtensionConformanceAndMultipleInheritance() {
        let source = """
            final class Box: Base, @unchecked Sendable {}
            extension Other: @unchecked Sendable {}
            """
        #expect(rules(in: source) == ["unchecked-sendable", "unchecked-sendable"])
    }

    @Test func reportsAtTheAttribute() {
        let found = findings(in: "final class Box: @unchecked Sendable {}\n")
        #expect(found.first?.line == 1)
        #expect(found.first?.column == 18)
    }

    @Test func plainSendableIsFine() {
        #expect(rules(in: "struct Value: Sendable {}\nfinal class A: Sendable {}\n") == [])
    }

    @Test func otherUncheckedUsesAreIgnored() {
        #expect(rules(in: "final class A: @unchecked Equatable {}\n") == [])
    }

    @Test func aJustificationOnThePrecedingLineSuppresses() {
        let source = """
            // stoic:allow(unchecked-sendable): every access goes through `lock`
            final class Box: @unchecked Sendable {}
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationOnTheSameLineSuppresses() {
        let source = "final class Box: @unchecked Sendable {} // stoic:allow(unchecked-sendable): lock-guarded\n"
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationAboveAMultiLineDeclarationCoversTheClause() {
        let source = """
            // stoic:allow(unchecked-sendable): every access goes through `lock`
            final class Box:
                Base,
                @unchecked Sendable
            {
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationForAnotherRuleDoesNotApply() {
        let source = """
            // stoic:allow(force-try): not this rule
            final class Box: @unchecked Sendable {}
            """
        #expect(rules(in: source) == ["unchecked-sendable"])
    }

    @Test func theQualifiedRuleNameIsAccepted() {
        let source = """
            // stoic:allow(stoic.unchecked-sendable): lock-guarded
            final class Box: @unchecked Sendable {}
            """
        #expect(rules(in: source) == [])
    }

    @Test func aTrailingCommentDoesNotSpeakForTheNextLine() {
        let source = """
            let a = 1 // stoic:allow(unchecked-sendable): this is about `a`
            final class Box: @unchecked Sendable {}
            """
        #expect(rules(in: source) == ["unchecked-sendable"])
    }

    @Test func aReasonlessAllowDoesNotSuppressAndIsReported() {
        let source = """
            // stoic:allow(unchecked-sendable)
            final class Box: @unchecked Sendable {}
            """
        #expect(rules(in: source) == ["allow-without-reason", "unchecked-sendable"])
    }
}

@Suite("nonisolated-unsafe")
struct NonisolatedUnsafeTests {
    @Test func flagsAGlobalAndAProperty() {
        let source = """
            nonisolated(unsafe) var counter = 0
            final class A {
                nonisolated(unsafe) var state = 0
            }
            """
        #expect(rules(in: source) == ["nonisolated-unsafe", "nonisolated-unsafe"])
    }

    @Test func otherNonisolatedFormsAreFine() {
        let source = """
            nonisolated let constant = 1
            actor A {
                nonisolated func f() {}
                nonisolated(nonsending) func g() async {}
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            // stoic:allow(nonisolated-unsafe): written once before any task starts
            nonisolated(unsafe) var counter = 0
            """
        #expect(rules(in: source) == [])
    }
}

@Suite("task-detached")
struct TaskDetachedTests {
    @Test func flagsDetached() {
        let source = """
            func f() {
                Task.detached { work() }
                Task.detached(priority: .background) { work() }
                Task<Void, Never>.detached { work() }
            }
            """
        #expect(rules(in: source) == ["task-detached", "task-detached", "task-detached"])
    }

    @Test func plainTasksAreFine() {
        let source = """
            func f() {
                Task { work() }
                Task(priority: .background) { work() }
                let detached = 1
                other.detached { }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func f() {
                // stoic:allow(task-detached): must outlive the caller's task-locals
                Task.detached { work() }
            }
            """
        #expect(rules(in: source) == [])
    }
}

@Suite("sleep-for-timeout")
struct SleepForTimeoutTests {
    @Test func flagsAsyncAfter() {
        let source = """
            func f() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { timeout() }
                queue.asyncAfter(wallDeadline: .now() + 1) { timeout() }
            }
            """
        #expect(rules(in: source) == ["sleep-for-timeout", "sleep-for-timeout"])
    }

    @Test func plainDispatchIsFine() {
        let source = """
            func f() {
                DispatchQueue.main.async { work() }
                asyncAfter(1)
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func f() {
                // stoic:allow(sleep-for-timeout): AppKit gives no async API for this callback
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { timeout() }
            }
            """
        #expect(rules(in: source) == [])
    }
}

@Suite("unbounded-stream")
struct UnboundedStreamTests {
    @Test func flagsAStreamWithNoPolicy() {
        let source = """
            let a = AsyncStream<Int> { continuation in continuation.finish() }
            let b = AsyncThrowingStream(Int.self) { continuation in continuation.finish() }
            let c = AsyncStream<Int>.makeStream()
            let d = AsyncStream<Int>.makeStream(of: Int.self)
            let e = AsyncStream<Int>.init { _ in }
            """
        #expect(rules(in: source) == Array(repeating: "unbounded-stream", count: 5))
    }

    @Test func flagsAnExplicitUnboundedPolicy() {
        let source = """
            let a = AsyncStream<Int>(bufferingPolicy: .unbounded) { _ in }
            let b = AsyncStream<Int>.makeStream(bufferingPolicy: .unbounded)
            """
        #expect(rules(in: source) == ["unbounded-stream", "unbounded-stream"])
    }

    @Test func aBoundedPolicyIsFine() {
        let source = """
            let a = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(1)) { _ in }
            let b = AsyncStream(Int.self, bufferingPolicy: .bufferingOldest(8)) { _ in }
            let c = AsyncThrowingStream<Int, any Error>.makeStream(bufferingPolicy: .bufferingNewest(4))
            """
        #expect(rules(in: source) == [])
    }

    @Test func aPolicyPassedAsAVariableIsTrusted() {
        #expect(rules(in: "let a = AsyncStream<Int>(bufferingPolicy: policy) { _ in }\n") == [])
    }

    @Test func pullBasedStreamsBufferNothing() {
        #expect(rules(in: "let a = AsyncStream<Int>(unfolding: { await next() })\n") == [])
    }

    @Test func mentioningTheTypeIsFine() {
        let source = """
            func f(_ stream: AsyncStream<Int>) -> AsyncStream<Int>.Continuation? { nil }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            // stoic:allow(unbounded-stream): at most 3 elements are ever produced
            let a = AsyncStream<Int> { _ in }
            """
        #expect(rules(in: source) == [])
    }
}
#endif
