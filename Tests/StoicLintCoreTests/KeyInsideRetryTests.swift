#if STOIC_LINT
import StoicLintCore
import Testing

@Suite("key-inside-retry")
struct KeyInsideRetryTests {
    private let rule = "key-inside-retry"

    @Test func aKeyDrawnInTheOperationIsFlagged() {
        let source = """
            func pay() async throws {
                try await retry(.exponential(base: .seconds(1)).attempts(5)) { _ in
                    try await payments.charge(order, idempotencyKey: IdempotencyKey.random())
                }
            }
            """
        #expect(rules(in: source) == [rule])
    }

    @Test func everyFormOfRetryAndNestingIsSeen() {
        let source = """
            func pay() async throws {
                try await retry(schedule, attemptTimeout: .seconds(2)) { attempt in
                    let key = IdempotencyKey.random()
                    try await payments.charge(order, idempotencyKey: key)
                }
                try await Stoic.retry(schedule, operation: { _ in
                    try await send(IdempotencyKey.random(fileID: #fileID, line: #line))
                })
                try await retry(schedule) { _ in
                    try await withContext("charging") {
                        try await send(IdempotencyKey.random())
                    }
                }
            }
            """
        #expect(rules(in: source) == [rule, rule, rule])
    }

    @Test func reportsAtTheCall() throws {
        let source = """
            func pay() async throws {
                try await retry(schedule) { _ in
                    let key = IdempotencyKey.random()
                    try await send(key)
                }
            }
            """
        let found = try #require(findings(in: source).first)
        #expect(found.line == 3)
        #expect(found.column == 19)
        #expect(found.fixIt?.contains("attempt.idempotencyKey") == true)
    }

    @Test func aKeyDrawnBeforeTheRetryIsFine() {
        let source = """
            func pay() async throws {
                let key = IdempotencyKey.random()
                try await retry(.exponential(base: .seconds(1)).attempts(5)) { _ in
                    try await payments.charge(order, idempotencyKey: key)
                }
                try await retry(schedule) { attempt in
                    try await payments.charge(order, idempotencyKey: attempt.idempotencyKey)
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aKeyFromAStableValueIsFine() {
        let source = """
            func pay() async throws {
                try await retry(schedule) { _ in
                    try await payments.charge(order, idempotencyKey: IdempotencyKey(rawValue: order.id))
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aKeyInAnArgumentThatIsNotTheOperationIsFine() {
        // The schedule is evaluated once, before any attempt.
        let source = """
            func pay() async throws {
                try await retry(makeSchedule(IdempotencyKey.random())) { _ in try await send() }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func otherRepeatersAreNotRetry() {
        // `recur` repeats after success: each run is a new operation, and a
        // new key per run is right.
        let source = """
            func poll() async throws {
                try await recur(.fixed(.seconds(5))) { _ in
                    try await send(IdempotencyKey.random())
                    return .continue
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { try? await send(IdempotencyKey.random()) }
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func otherRandomCallsAreNotKeys() {
        let source = """
            func f() async throws {
                try await retry(schedule) { _ in
                    let jitter = Double.random(in: 0...1)
                    let id = UUID.random()
                    try await send(id, jitter)
                }
            }
            """
        #expect(rules(in: source) == [])
    }

    @Test func aJustificationSuppresses() {
        let source = """
            func f() async throws {
                try await retry(schedule) { _ in
                    // stoic:allow(key-inside-retry): the server rejects reused keys after a timeout; a fresh one is what it wants
                    try await send(IdempotencyKey.random())
                }
            }
            """
        #expect(rules(in: source) == [])
    }
}
#endif
