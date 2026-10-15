#if STOIC_LINT
import StoicLintCore
import Testing

@Suite("blocking-in-async")
struct BlockingInAsyncTests {
    private let blocking = "blocking-in-async"

    @Test func aSynchronousFunctionMayBlock() {
        let source = """
            func f() {
                semaphore.wait()
                sleep(1)
                usleep(10)
                Thread.sleep(forTimeInterval: 1)
                DispatchQueue.main.sync { }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func anAsyncFunctionMayNot() {
        let source = """
            func f() async {
                semaphore.wait()
                group.wait(timeout: .now() + 1)
                sleep(1)
                usleep(10)
                Thread.sleep(forTimeInterval: 1)
                DispatchQueue.main.sync { }
                queue.sync(execute: work)
            }
            """
        #expect(rules(in: source) == Array(repeating: blocking, count: 7))
    }

    @Test func reportsTheCallAndSuggestsTheFix() throws {
        let found = findings(
            in: """
                func f() async {
                    semaphore.wait()
                }
                """)
        let first = try #require(found.first)
        #expect(first.line == 2)
        #expect(first.column == 5)
        #expect(first.message.contains("cooperative pool"))
        #expect(first.fixIt?.contains("AsyncSemaphore") == true)
        let sleeping = try #require(
            findings(in: "func f() async { sleep(1) }\n").first)
        #expect(sleeping.fixIt?.contains("Ambient.sleep(for:)") == true)
    }

    @Test func anAsyncClosureInsideASynchronousFunctionIsFlagged() {
        let source = """
            func f() {
                Task { sleep(1) }
                let work = { () async in usleep(5) }
                Task.detached { semaphore.wait() }
                group.addTask { Thread.sleep(forTimeInterval: 1) }
            }
            """
        // Task.detached is another rule's business: only the blocking calls count here.
        #expect(rules(in: source).filter { $0 == blocking }.count == 4)
    }

    @Test func aSynchronousClosureInsideAnAsyncFunctionIsTreatedAsSynchronous() {
        // The sanctioned bridge: blocking work handed to a Dispatch thread.
        let source = """
            func f() async {
                DispatchQueue.global().async { semaphore.wait() }
                let values = items.map { _ in sleep(1) }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aNestedSynchronousFunctionResetsTheContext() {
        let source = """
            func f() async {
                func helper() { sleep(1) }
            }
            func g() {
                func helper() async { sleep(1) }
            }
            """
        #expect(rules(in: source) == [blocking])
    }

    @Test func actorMethodsAreAsyncContexts() {
        let source = """
            actor Cache {
                func load() { semaphore.wait() }
                init() { usleep(5) }
                var value: Int { sleep(1); return 1 }
                nonisolated func fine() { sleep(1) }
                static func alsoFine() { sleep(1) }
                nonisolated var fineToo: Int { sleep(1); return 1 }
            }
            """
        #expect(rules(in: source) == [blocking, blocking, blocking])
    }

    @Test func aClassMethodIsNotAnActorMethod() {
        let source = """
            final class Cache {
                func load() { semaphore.wait() }
                var value: Int { sleep(1); return 1 }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aLocalVariableInAnActorMethodIsNotAnActorBody() {
        let source = """
            actor Cache {
                func load() async {
                    let handler = { sleep(1) }
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func waitOnAnUnrelatedReceiverIsNotASemaphore() {
        let source = """
            func f() async {
                process.wait()
                condition.wait()
                await group.waitForAll()
                await task.wait()
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func semaphoreAndGroupReceiversAreRecognizedBySpelling() {
        let source = """
            func f() async {
                self.requestSemaphore.wait()
                DispatchSemaphore(value: 0).wait()
                sem.wait()
                downloadGroup.wait()
                dispatchGroup.wait(wallTimeout: .distantFuture)
            }
            """
        #expect(rules(in: source) == Array(repeating: blocking, count: 5))
    }

    @Test func labeledSleepAndOtherSleepsAreNotTheCFunction() {
        let source = """
            func f() async throws {
                try await Ambient.sleep(for: .seconds(1))
                try await clock.sleep(for: .seconds(1))
                try await Task.sleep(for: .seconds(1))
                sleep(for: .seconds(1))
                sleep(1, 2)
            }
            """
        // `Task.sleep` is `bare-task-sleep`'s business, not this rule's.
        #expect(rules(in: source) == ["bare-task-sleep"])
    }

    @Test func moduleQualifiedCFunctionsAreFlagged() {
        let source = """
            func f() async {
                Darwin.sleep(1)
                Glibc.usleep(1)
            }
            """
        #expect(rules(in: source) == [blocking, blocking])
    }

    @Test func syncOnANonQueueIsNotDispatch() {
        let source = """
            func f() async {
                store.sync()
                database.sync { }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func stoicAndStandardTaskBodiesAreAsync() {
        let source = """
            func f() {
                withTaskGroup(of: Int.self) { group in sleep(1) }
                MainActor.run { sleep(1) }
                withTimeout(.seconds(1)) { sleep(1) }
            }
            """
        #expect(rules(in: source) == [blocking, blocking, blocking])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func f() async {
                // stoic:allow(blocking-in-async): runs on a dedicated thread before the pool starts
                semaphore.wait()
            }
            """
        #expect(rules(in: source) == [])
    }
}
#endif
