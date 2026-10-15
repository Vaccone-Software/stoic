#if STOIC_LINT
import StoicLintCore
import Testing

@Suite("hand-rolled-retry")
struct HandRolledRetryTests {
    private let rule = "hand-rolled-retry"

    /// This rule's findings only: real loops pair with other rules
    /// (`try? await sleep` is also a discarded `try?`), which have their own tests.
    private func hits(_ source: String) -> [String] { rules(in: source).filter { $0 == rule } }

    @Test func everyLoopKindIsSeen() {
        let source = """
            func fetch() async throws -> Data {
                for attempt in 1...5 {
                    do { return try await api.fetch() } catch { try await clock.sleep(for: .seconds(attempt)) }
                }
                var attempts = 0
                while attempts < 5 {
                    do { return try await api.fetch() } catch { attempts += 1; try await Ambient.sleep(for: .seconds(1)) }
                }
                repeat {
                    do { return try await api.fetch() } catch { try await Task.sleep(for: .seconds(1), clock: clock) }
                } while true
                throw Exhausted()
            }
            """
        #expect(hits(source) == [rule, rule, rule])
    }

    @Test func aWhileTrueThatReturnsOnSuccessIsARetryNotAKeepAlive() {
        let source = """
            func fetch() async throws -> Data {
                var attempts = 0
                while true {
                    do {
                        return try await api.fetch()
                    } catch {
                        attempts += 1
                        if attempts >= 5 { throw error }
                        try await Ambient.sleep(for: .seconds(1))
                    }
                }
            }
            """
        #expect(hits(source) == [rule])
    }

    @Test func breakingOutOnSuccessCounts() {
        let source = """
            func sync() async {
                for _ in 0..<3 {
                    do { try await engine.sync(); break } catch { try? await Ambient.sleep(for: .seconds(2)) }
                }
            }
            """
        #expect(hits(source) == [rule])
    }

    @Test func reportsAtTheLoopKeyword() throws {
        let source = """
            func fetch() async throws -> Data {
                for attempt in 1...5 {
                    do { return try await api.fetch() } catch { try await Ambient.sleep(for: .seconds(1)) }
                }
                throw Exhausted()
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.rule.shortName == rule)
        #expect(found.line == 2)
        #expect(found.column == 5)
        #expect(found.fixIt?.contains("retry(") == true)
    }

    @Test func aPacingLoopIsNotARetry() {
        // Sleeps every time round, success or not: rate pacing.
        let source = """
            func upload(_ items: [Item]) async {
                for item in items {
                    do { try await api.upload(item) } catch { failed.append(item) }
                    try? await Ambient.sleep(for: .milliseconds(100))
                }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func aLoopWhoseCatchDoesNotSleepIsNotARetry() {
        let source = """
            func first(_ mirrors: [URL]) async throws -> Data {
                for mirror in mirrors {
                    do { return try await download(mirror) } catch { log(error) }
                }
                throw NoMirror()
            }
            """
        #expect(hits(source) == [])
    }

    @Test func aBreakThatEndsASwitchDoesNotLeaveTheLoop() {
        // The `break` ends the `switch`; with no exit on success this is not
        // a retry (and a `for` is never a keep-alive loop).
        let source = """
            func drain() async {
                for item in items {
                    do {
                        switch try await process(item) {
                        case .done: break
                        case .more: queue.append(item)
                        }
                    } catch {
                        try? await Ambient.sleep(for: .seconds(1))
                    }
                }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func aLabeledBreakInsideASwitchLeavesTheLoop() {
        let source = """
            func drain() async {
                outer: for _ in 0..<5 {
                    do {
                        switch try await process() {
                        case .done: break outer
                        case .more: continue
                        }
                    } catch {
                        try? await Ambient.sleep(for: .seconds(1))
                    }
                }
            }
            """
        #expect(hits(source) == [rule])
    }

    @Test func aRetryInsideAClosureOrInnerLoopIsJudgedThere() {
        let source = """
            func f() async {
                for group in groups {
                    let work = {
                        do { return try await api.fetch(group) } catch { try? await Ambient.sleep(for: .seconds(1)) }
                    }
                    for attempt in 1...3 {
                        do { try await api.send(group); break } catch { try? await Ambient.sleep(for: .seconds(attempt)) }
                    }
                }
            }
            """
        // Only the inner `for`: the closure is not a loop, and the outer loop's
        // own body has no `do`.
        #expect(hits(source) == [rule])
    }

    @Test func retryItselfIsFine() {
        let source = """
            func fetch() async throws -> Data {
                try await retry(.exponential(base: .seconds(1)).attempts(5)) { _ in try await api.fetch() }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func aJustificationAboveTheLoopSuppresses() {
        let source = """
            func probe() async {
                // stoic:allow(hand-rolled-retry): a hardware probe whose retries are its protocol, not failure handling
                for attempt in 1...3 {
                    do { try await device.probe(); break } catch { try? await Ambient.sleep(for: .milliseconds(attempt * 10)) }
                }
            }
            """
        #expect(hits(source) == [])
    }
}

@Suite("keep-alive-loop")
struct KeepAliveLoopTests {
    private let rule = "keep-alive-loop"

    /// This rule's findings only: real loops pair with other rules
    /// (`try? await sleep` is also a discarded `try?`), which have their own tests.
    private func hits(_ source: String) -> [String] { rules(in: source).filter { $0 == rule } }

    @Test func everyForeverShapeIsSeen() {
        let source = """
            func keepSyncing() async {
                while true {
                    do { try await engine.run() } catch { try? await Ambient.sleep(for: .seconds(5)) }
                }
                while !Task.isCancelled {
                    do { try await listener.serve() } catch { log(error); try? await clock.sleep(for: .seconds(1)) }
                }
                repeat {
                    do { try await tap.run() } catch { try? await Ambient.sleep(for: .seconds(1)) }
                } while true
                repeat {
                    do { try await tap.run() } catch { try? await Ambient.sleep(for: .seconds(1)) }
                } while !Task.isCancelled
            }
            """
        #expect(hits(source) == [rule, rule, rule, rule])
    }

    @Test func reportsAtTheLoopKeyword() throws {
        let source = """
            func keepSyncing() async {
                while true {
                    do { try await engine.run() } catch { try? await Ambient.sleep(for: .seconds(5)) }
                }
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.rule.shortName == rule)
        #expect(found.line == 2)
        #expect(found.column == 5)
        #expect(found.fixIt?.contains("Supervisor") == true)
    }

    @Test func aBoundedLoopIsNotKeepingAnythingAlive() {
        let source = """
            func f() async {
                while queue.hasWork {
                    do { try await queue.processNext() } catch { try? await Ambient.sleep(for: .seconds(1)) }
                }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func aForeverLoopThatDoesNotBackOffIsNotThisRule() {
        // An event loop: no sleep in the catch.
        let source = """
            func pump() async {
                while true {
                    do { try await handle(await events.next()) } catch { report(error) }
                }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func aSupervisorIsFine() {
        let source = """
            func start() async throws {
                let supervisor = Supervisor(label: "app", strategy: .oneForOne) {
                    Child("sync", restart: .permanent) { _ in try await engine.run() }
                }
                try await supervisor.run()
            }
            """
        #expect(hits(source) == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func keepSyncing() async {
                // stoic:allow(keep-alive-loop): the supervisor's own restart loop
                while true {
                    do { try await engine.run() } catch { try? await Ambient.sleep(for: .seconds(5)) }
                }
            }
            """
        #expect(hits(source) == [])
    }
}

@Suite("unbounded-task-group")
struct UnboundedTaskGroupTests {
    private let rule = "unbounded-task-group"

    /// This rule's findings only: real loops pair with other rules
    /// (`try? await sleep` is also a discarded `try?`), which have their own tests.
    private func hits(_ source: String) -> [String] { rules(in: source).filter { $0 == rule } }

    @Test func oneTaskPerElementIsFlagged() {
        let source = """
            func fetchAll(_ urls: [URL]) async throws {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    for url in urls {
                        group.addTask { try await fetch(url) }
                    }
                    for url in urls.indices {
                        group.addTaskUnlessCancelled { try await fetch(urls[url]) }
                    }
                    for (index, url) in urls.enumerated() where index > 0 {
                        if url.isFileURL { continue }
                        group.addTask { try await fetch(url) }
                    }
                }
            }
            """
        #expect(hits(source) == [rule, rule, rule])
    }

    @Test func reportsAtTheMemberName() throws {
        let source = """
            func fetchAll(_ urls: [URL]) async {
                await withTaskGroup(of: Void.self) { group in
                    for url in urls {
                        group.addTask { await fetch(url) }
                    }
                }
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.rule.shortName == rule)
        #expect(found.line == 4)
        #expect(found.column == 19)
        #expect(found.fixIt?.contains("mapConcurrent") == true)
    }

    @Test func aRangeOfWorkersIsBounded() {
        let source = """
            func drain(_ queue: WorkQueue) async {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<workerCount { group.addTask { await queue.work() } }
                    for _ in 1...4 { group.addTask { await queue.work() } }
                    for _ in (0..<limit) { group.addTask { await queue.work() } }
                    for index in stride(from: 0, to: count, by: chunk) { group.addTask { await work(index) } }
                }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func aSlidingWindowIsBounded() {
        let source = """
            func fetchAll(_ urls: [URL]) async {
                await withTaskGroup(of: Void.self) { group in
                    var running = 0
                    for url in urls {
                        if running >= 8 { await group.next(); running -= 1 }
                        group.addTask { await fetch(url) }
                        running += 1
                    }
                }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func anAsyncSequenceIsNotJudged() {
        let source = """
            func serve() async {
                await withDiscardingTaskGroup { group in
                    for await connection in listener.connections {
                        group.addTask { await handle(connection) }
                    }
                }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func anAddTaskInsideAClosureInTheLoopIsNotDirectlyInIt() {
        let source = """
            func f() async {
                await withTaskGroup(of: Void.self) { group in
                    for item in items {
                        let add = { group.addTask { await work(item) } }
                        handlers.append(add)
                    }
                    group.addTask { await work(first) }
                }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func mapConcurrentIsFine() {
        let source = """
            func fetchAll(_ urls: [URL]) async throws -> [Data] {
                try await mapConcurrent(urls, limit: 8) { url in try await fetch(url) }
            }
            """
        #expect(hits(source) == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func race() async {
                await withTaskGroup(of: Void.self) { group in
                    for racer in racers {
                        // stoic:allow(unbounded-task-group): a race runs every racer at once by definition
                        group.addTask { await racer.run() }
                    }
                }
            }
            """
        #expect(hits(source) == [])
    }
}

@Suite("unsafe-continuation")
struct UnsafeContinuationTests {
    private let rule = "unsafe-continuation"

    @Test func bothUnsafeFormsAreFlagged() {
        let source = """
            func wait() async throws {
                await withUnsafeContinuation { continuation in callback { continuation.resume() } }
                try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<Void, any Error>) in
                    callback { continuation.resume() }
                }
            }
            """
        #expect(rules(in: source) == [rule, rule])
    }

    @Test func reportsAtTheCallee() throws {
        let found = try #require(
            findings(in: "func f() async {\n    await withUnsafeContinuation { $0.resume() }\n}\n").first)
        #expect(found.line == 2)
        #expect(found.column == 11)
        #expect(found.fixIt?.contains("withCheckedContinuation") == true)
    }

    @Test func checkedContinuationsAreFine() {
        let source = """
            func wait() async throws {
                await withCheckedContinuation { continuation in callback { continuation.resume() } }
                try await withCheckedThrowingContinuation { continuation in callback { continuation.resume() } }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aMentionThatIsNotACallIsIgnored() {
        let source = """
            typealias Waiter = UnsafeContinuation<Void, Never>
            let name = "withUnsafeContinuation"
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func wait() async {
                // stoic:allow(unsafe-continuation): resumed exactly once by the audio thread; measured hot path
                await withUnsafeContinuation { continuation in engine.onRender { continuation.resume() } }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func testCodeIsNotExempt() {
        let source = "func f() async {\n    await withUnsafeContinuation { $0.resume() }\n}\n"
        #expect(rules(in: source, path: "/work/Tests/AppTests/WaitTests.swift") == [rule])
    }
}
#endif
