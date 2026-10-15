#if STOIC_LINT
import StoicLintCore
import Testing

@Suite("swallowed-cancellation")
struct SwallowedCancellationTests {
    private let rule = "swallowed-cancellation"

    @Test func everyPatternThatNamesCancellationIsSeen() {
        let source = """
            func f() async {
                for item in items {
                    do { try await work(item) } catch is CancellationError {}
                    do { try await work(item) } catch let error as CancellationError { log(error) }
                    do { try await work(item) } catch _ as CancellationError { continue }
                    do { try await work(item) } catch is CancellationError, is TimeoutError { count += 1 }
                }
            }
            """
        #expect(rules(in: source) == Array(repeating: rule, count: 4))
    }

    @Test func reportsAtTheCatchKeyword() throws {
        let source = """
            func f() async {
                while true {
                    do {
                        try await work()
                    } catch is CancellationError {
                    }
                    step()
                }
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.rule.shortName == rule)
        #expect(found.line == 5)
        #expect(found.column == 11)
        #expect(found.fixIt?.contains("propagate") == true)
    }

    @Test func aClauseThatLeavesIsFine() {
        let source = """
            func f() async throws -> Int {
                while true {
                    do { try await work() } catch let error as CancellationError { throw error }
                    do { try await work() } catch is CancellationError { throw Stopped() }
                    do { try await work() } catch is CancellationError { return 0 }
                    do { try await work() } catch is CancellationError { cleanUp(); break }
                    do { try await work() } catch is CancellationError { fatalError("unreachable") }
                    do { try await work() } catch is CancellationError { if done { return 1 } else { throw Stopped() } }
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func fallingOffTheEndOfABodyIsReturning() {
        let source = """
            func f() async {
                prepare()
                do { try await work() } catch is CancellationError { state = .cancelled }
            }
            let task = Task {
                do { try await work() } catch is CancellationError {}
            }
            var value: Int {
                get async {
                    do { try await work() } catch is CancellationError {}
                }
            }
            final class Owner {
                init() async {
                    do { try await work() } catch is CancellationError {}
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func fallingOffTheEndThroughNestedConstructsIsReturning() {
        let source = """
            func f() async {
                if ready {
                    do { try await work() } catch is CancellationError {}
                } else if other {
                    switch mode {
                    case .a:
                        do { try await work() } catch is CancellationError {}
                    default:
                        break
                    }
                } else {
                    do {
                        do { try await work() } catch is CancellationError {}
                    } catch {
                        do { try await work() } catch is CancellationError {}
                    }
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aLoopInBetweenIsNotTheEnd() {
        let source = """
            func f() async {
                for item in items {
                    if ready {
                        do { try await work(item) } catch is CancellationError {}
                    }
                }
                repeat {
                    do { try await work() } catch is CancellationError {}
                } while true
            }
            """
        #expect(rules(in: source) == [rule, rule])
    }

    @Test func fallingThroughIntoMoreWorkIsFlagged() {
        let source = """
            func f() async {
                do { try await work() } catch is CancellationError { state = .cancelled }
                await moreWork()
            }
            let task = Task {
                if ready {
                    do { try await work() } catch is CancellationError {}
                }
                await moreWork()
            }
            """
        #expect(rules(in: source) == [rule, rule])
    }

    @Test func anExitInsideANestedClosureDoesNotCount() {
        let source = """
            func f() async {
                while true {
                    do { try await work() } catch is CancellationError {
                        let handler = { return }
                        handler()
                    }
                }
            }
            """
        #expect(rules(in: source) == [rule])
    }

    @Test func aCatchAllOverOnlySleepsIsACancellationCatch() {
        let source = """
            func poll() async {
                while true {
                    do { try await clock.sleep(for: .seconds(1)) } catch {}
                    refresh()
                }
            }
            """
        #expect(rules(in: source) == [rule])
    }

    @Test func aTimerThatEndsWhenCancelledIsFine() {
        let source = """
            func arm() {
                timer = Task.stoic {
                    do {
                        try await clock.sleep(until: deadline, tolerance: nil)
                        fire()
                    } catch {}
                }
                group.addTask {
                    do {
                        while true {
                            try await Ambient.sleep(for: .seconds(1))
                            beat()
                        }
                    } catch {}
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aCatchAllOverOtherWorkIsNotACancellationCatch() {
        let source = """
            func f() async {
                while true {
                    do {
                        try await clock.sleep(for: .seconds(1))
                        try await refresh()
                    } catch {
                        failures += 1
                    }
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func otherErrorTypesAreNotThisRule() {
        let source = """
            func f() async {
                while true {
                    do { try await work() } catch is TimeoutError {}
                    do { try await work() } catch let error as URLError { log(error) }
                }
            }
            """
        #expect(!rules(in: source).contains(rule))
    }

    @Test func testCodeIsExempt() {
        let source = """
            func f() async {
                do { try await work() } catch is CancellationError { cancelled = true }
                #expect(cancelled)
            }
            """
        #expect(rules(in: source, path: "/work/Tests/AppTests/CancelTests.swift") == [])
    }

    @Test func aJustificationOnTheCatchLineSuppresses() {
        let source = """
            func f() async {
                while true {
                    do {
                        try await work()
                    } catch is CancellationError {  // stoic:allow(swallowed-cancellation): the next turn returns the rejection
                        leave()
                    }
                }
            }
            """
        #expect(rules(in: source) == [])
    }
}

@Suite("swallowed-error")
struct SwallowedErrorTests {
    private let rule = "swallowed-error"

    @Test func anEmptyCatchAllIsFlagged() {
        let source = """
            func f() {
                do { try save() } catch {}
                do { try save() } catch let error {}
                do { try save() } catch var e {}
                do { try save() } catch _ {}
                do { try save() } catch {
                    // fine, probably
                }
            }
            """
        #expect(rules(in: source) == Array(repeating: rule, count: 5))
    }

    @Test func aCatchThatOnlyPrintsIsFlagged() {
        let source = """
            func f() {
                do { try save() } catch { print(error) }
                do { try save() } catch { print("save failed"); debugPrint(error) }
                do { try save() } catch let failure { dump(failure) }
                do { try save() } catch { NSLog("%@", "\\(error)") }
            }
            """
        #expect(rules(in: source) == Array(repeating: rule, count: 4))
    }

    @Test func theMessageSaysWhichKind() throws {
        let empty = try #require(findings(in: "func f() {\n    do { try save() } catch {}\n}\n").first)
        let printed = try #require(findings(in: "func f() {\n    do { try save() } catch { print(error) }\n}\n").first)
        #expect(empty.message.contains("discards every error"))
        #expect(printed.message.contains("only prints"))
        #expect(empty.line == 2)
        #expect(empty.column == 23)
    }

    @Test func aCatchThatDoesSomethingIsFine() {
        let source = """
            func f() throws {
                do { try save() } catch { throw Wrapped(error) }
                do { try save() } catch { logger.error("save failed: \\(error)") }
                do { try save() } catch { print(error); retryLater() }
                do { try save() } catch { state = .failed(error) }
                do { try save() } catch { return }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aClauseThatNamesTheErrorIsHandlingIt() {
        let source = """
            func f() {
                do { try remove(path) } catch CocoaError.fileNoSuchFile {}
                do { try remove(path) } catch is NotFound {}
                do { try remove(path) } catch let error as NotFound { print(error) }
                do { try remove(path) } catch let error where error.isBenign {}
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aSecondaryFailureWhileRethrowingIsFine() {
        let source = """
            func read() throws(StoreError) -> [UInt8] {
                do throws(StoreError) {
                    return try fileSystem.read(file)
                } catch {
                    do throws(StoreError) {
                        try fileSystem.close(file)
                    } catch {}
                    throw error
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aNestedCatchIsStillFlaggedWhenTheOuterOneSwallowsToo() {
        let source = """
            func read() {
                do {
                    try fileSystem.read(file)
                } catch {
                    do { try fileSystem.close(file) } catch {}
                    recover()
                }
            }
            """
        #expect(rules(in: source) == [rule])
    }

    @Test func aRethrowInsideAClosureDoesNotMakeItSecondary() {
        let source = """
            func f() {
                do {
                    try work()
                } catch {
                    let later = {
                        do { try close() } catch {}
                    }
                    throw error
                }
            }
            """
        #expect(rules(in: source) == [rule])
    }

    @Test func aCatchAllOverOnlySleepsIsLeftToTheCancellationRule() {
        let source = """
            func arm() {
                Task {
                    do { try await Task.sleep(for: .seconds(1), clock: clock); fire() } catch {}
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func testCodeIsExempt() {
        let source = "func f() {\n    do { try save() } catch {}\n}\n"
        #expect(rules(in: source, path: "/work/Tests/AppTests/SaveTests.swift") == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func close() {
                do { try handle.close() } catch {}  // stoic:allow(swallowed-error): nothing can be reported from a deinit
                // stoic:allow(swallowed-error): best effort; the next launch removes it
                do { try remove(temporary) } catch {}
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationWithoutAReasonDoesNotSuppress() {
        let source = """
            func close() {
                do { try handle.close() } catch {}  // stoic:allow(swallowed-error)
            }
            """
        #expect(rules(in: source).sorted() == ["allow-without-reason", rule])
    }
}
#endif
