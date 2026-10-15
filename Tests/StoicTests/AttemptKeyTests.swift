@testable import Stoic
import StoicTesting
import Testing

/// `attempt.idempotencyKey`: one key per operation, handed to every attempt.
@Suite("Attempt keys")
struct AttemptKeyTests {
    struct Lost: Error {}
    static let schedule = Schedule.fixed(.seconds(1)).attempts(4)

    @Test(.failureMode("design/02", "every attempt sends attempt.idempotencyKey"))
    func everyAttemptOfOneRetrySendsTheSameKey() async throws {
        let seen = SendableBox<[IdempotencyKey]>([])
        let value = try await withTestAmbient(clock: ImmediateClock()) {
            try await retry(Self.schedule) { attempt throws(Lost) -> Int in
                seen.mutate { $0.append(attempt.idempotencyKey) }
                // Read twice in one attempt: still the one key.
                seen.mutate { $0.append(attempt.idempotencyKey) }
                if attempt.number < 4 { throw Lost() }
                return attempt.number
            }
        }
        #expect(value == 4)
        #expect(seen.value.count == 8)
        #expect(Set(seen.value).count == 1)
    }

    @Test func attemptsBoundedByATimeoutShareTheKeyToo() async throws {
        // This form runs each attempt in a child task.
        let seen = SendableBox<[IdempotencyKey]>([])
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await retry(Self.schedule, attemptTimeout: .seconds(5)) { attempt throws(Lost) -> Int in
                seen.mutate { $0.append(attempt.idempotencyKey) }
                if attempt.number < 3 { throw Lost() }
                return 1
            }
        }
        #expect(seen.value.count == 3)
        #expect(Set(seen.value).count == 1)
    }

    @Test(.failureMode("design/02", "the same call site retries twice"))
    func eachRetryIsItsOwnOperation() async {
        let keys = await withTestAmbient(clock: ImmediateClock()) {
            var keys: [IdempotencyKey] = []
            for _ in 0..<5 {
                keys.append(await retry(Self.schedule) { attempt in attempt.idempotencyKey })
            }
            return keys
        }
        #expect(Set(keys).count == 5)
    }

    @Test(.failureMode("design/02", "each run of recur sends attempt.idempotencyKey"))
    func eachRunOfRecurIsItsOwnOperation() async {
        let seen = SendableBox<[IdempotencyKey]>([])
        let outcome = await withTestAmbient(clock: ImmediateClock()) {
            await recur(.fixed(.seconds(1))) { run in
                seen.mutate { $0.append(run.idempotencyKey) }
                return run.number < 4 ? .continue : .stop
            }
        }
        #expect(outcome == .stopped)
        #expect(seen.value.count == 4)
        #expect(Set(seen.value).count == 4)
    }

    @Test(.failureMode("design/10", "hedged attempts send attempt.idempotencyKey"))
    func everyHedgedAttemptSendsTheSameKey() async {
        let clock = TestClock()
        let seen = SendableBox<[Int: IdempotencyKey]>([:])
        let task = Task {
            await withTestAmbient(clock: clock) {
                do throws(Lost) {
                    return try await hedge(.idempotent, after: .milliseconds(100), maxAttempts: 3) { attempt throws(Lost) -> Int in
                        seen.mutate { $0[attempt.number] = attempt.idempotencyKey }
                        // Attempts 1 and 2 are slow; attempt 3 is quick.
                        let work: Duration = attempt.number == 3 ? .milliseconds(10) : .seconds(10)
                        do { try await clock.sleep(until: .init(offset: attempt.elapsed + work), tolerance: nil) } catch { throw Lost() }
                        return attempt.number
                    }
                } catch {
                    return -1
                }
            }
        }
        await clock.waitForSleepers(count: 2)  // attempt 1 and the hedge timer
        await clock.advance(by: .milliseconds(100))
        await clock.waitForSleepers(count: 3)  // attempts 1 and 2, and the timer
        await clock.advance(by: .milliseconds(100))
        await clock.waitForSleepers(count: 3)  // attempts 1, 2 and 3
        await clock.advance(by: .milliseconds(10))
        #expect(await task.value == 3)
        #expect(seen.value.keys.sorted() == [1, 2, 3])
        #expect(Set(seen.value.values).count == 1)
    }

    @Test func concurrentFirstReadsDrawOneKey() async {
        // Hedged attempts can ask at the same instant; the draw happens once.
        for _ in 0..<50 {
            let identity = OperationIdentity(fileID: #fileID, line: #line)
            let keys = await withTaskGroup(of: IdempotencyKey.self) { group in
                for _ in 0..<16 { group.addTask { identity.idempotencyKey } }
                return await group.reduce(into: Set<IdempotencyKey>()) { $0.insert($1) }
            }
            #expect(keys.count == 1)
        }
    }

    @Test func theKeyIsReproducibleUnderASeed() async {
        func key(seed: UInt64) async -> IdempotencyKey {
            await withTestAmbient(clock: ImmediateClock(), seed: seed) {
                await retry(Self.schedule) { attempt in attempt.idempotencyKey }
            }
        }
        let first = await key(seed: 7)
        #expect(await key(seed: 7) == first)
        #expect(await key(seed: 8) != first)
    }

    @Test func theKeyIsTheOneDrawnByHandAtTheRetrysCallSite() async {
        let fromRetry = await withTestAmbient(clock: ImmediateClock(), seed: 21) {
            await retry(Self.schedule, fileID: "App/Payments.swift", line: 42) { attempt in attempt.idempotencyKey }
        }
        let byHand = await withTestAmbient(clock: ImmediateClock(), seed: 21) {
            IdempotencyKey.random(fileID: "App/Payments.swift", line: 42)
        }
        #expect(fromRetry == byHand)
        #expect(fromRetry.rawValue.count == 32 && fromRetry.rawValue.allSatisfy(\.isHexDigit))
    }

    /// The key drawn by hand after `work`, at one fixed call site.
    private static func keyDrawnAfter(seed: UInt64, _ work: () async -> Void) async -> IdempotencyKey {
        await withTestAmbient(clock: ImmediateClock(), seed: seed) {
            await work()
            return IdempotencyKey.random()
        }
    }

    @Test func anOperationThatNeverAsksDrawsNothing() async {
        // Seeded tests written before the key existed must see the same
        // random sequence: a retry that never reads the key draws nothing.
        let alone = await Self.keyDrawnAfter(seed: 4) {}
        let afterQuietRetry = await Self.keyDrawnAfter(seed: 4) {
            _ = await retry(Self.schedule) { attempt in attempt.number }
            _ = await recur(.fixed(.seconds(1))) { _ in .stop }
        }
        let afterAskingRetry = await Self.keyDrawnAfter(seed: 4) {
            _ = await retry(Self.schedule) { attempt in attempt.idempotencyKey }
        }
        #expect(afterQuietRetry == alone)
        #expect(afterAskingRetry != alone, "reading the key draws from the source, so the test can tell")
    }

    @Test func attemptsCompareByNumberAndElapsedTimeAlone() {
        let a = Attempt(number: 2, elapsed: .seconds(1), operation: OperationIdentity(fileID: #fileID, line: 1))
        let b = Attempt(number: 2, elapsed: .seconds(1), operation: OperationIdentity(fileID: #fileID, line: 2))
        let c = Attempt(number: 3, elapsed: .seconds(1), operation: OperationIdentity(fileID: #fileID, line: 1))
        let d = Attempt(number: 2, elapsed: .seconds(2), operation: OperationIdentity(fileID: #fileID, line: 1))
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
        #expect(a != d)
        #expect(Set([a, b, c, d]).count == 3)
        #expect(a.description == "attempt 2 at +1.0 seconds")
    }
}
