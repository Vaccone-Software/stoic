@testable import Stoic
import StoicTesting
import Testing

@Suite("Values")
struct ValueTests {
    struct Credentials { let user: String; let token: Secret<String> }

    @Test func aSecretNeverPrints() {
        let credentials = Credentials(user: "ada", token: Secret("hunter2"))
        #expect(!"\(credentials)".contains("hunter2"))
        #expect(!String(reflecting: credentials).contains("hunter2"))
        var dumped = ""
        dump(credentials, to: &dumped)
        #expect(!dumped.contains("hunter2"))
        #expect(credentials.token.reveal() == "hunter2")
        #expect(credentials.token.map(\.count).reveal() == 7)
        if case .string(let text) = Event.Value.secret(credentials.token) { #expect(text == "<redacted>") }
    }

    @Test func idempotencyKeysAreDistinctAndWellFormed() {
        let keys = (0..<1000).map { _ in IdempotencyKey.random() }
        #expect(Set(keys).count == 1000)
        #expect(keys.allSatisfy { $0.rawValue.count == 32 && $0.rawValue.allSatisfy(\.isHexDigit) })
    }

    /// Draws at one call site, as a test body would.
    private static func drawKeys(seed: UInt64) async -> [IdempotencyKey] {
        await withTestAmbient(clock: ImmediateClock(), seed: seed) {
            (0..<3).map { _ in IdempotencyKey.random() }
        }
    }

    @Test func seededKeysDoNotDependOnWhatOtherTestsDrew() async {
        let alone = await Self.drawKeys(seed: 5)
        // Other tests, other seeds, drawing keys in between.
        _ = await Self.drawKeys(seed: 6)
        _ = await Self.drawKeys(seed: 5)
        #expect(await Self.drawKeys(seed: 5) == alone)
        #expect(Set(alone).count == 3, "keys drawn at one site under one seed still differ")
        #expect(await Self.drawKeys(seed: 6) != alone)
    }

    @Test func seededKeysAreReproducibleInParallel() async {
        let runs = await withTaskGroup(of: [IdempotencyKey].self) { group in
            for _ in 0..<8 { group.addTask { await Self.drawKeys(seed: 11) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(runs).count == 1)
    }

    @Test func oneKeyServesEveryAttempt() async throws {
        let seen = SendableBox<[IdempotencyKey]>([])
        struct Lost: Error {}
        let key = IdempotencyKey.random()
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await retry(.fixed(.seconds(1)).attempts(3)) { attempt throws(Lost) -> Int in
                seen.mutate { $0.append(key) }
                if attempt.number < 3 { throw Lost() }
                return 1
            }
        }
        #expect(Set(seen.value).count == 1)
        #expect(seen.value.count == 3)
    }
}
