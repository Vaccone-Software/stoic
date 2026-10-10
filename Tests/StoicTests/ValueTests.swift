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
