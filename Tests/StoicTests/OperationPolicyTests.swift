@testable import Stoic
import StoicTesting
import Testing

/// `policy(at:)`: the derivation of design/22 as a table, so a changed
/// default is a reviewed diff.
@Suite("Operation policies")
struct OperationPolicyTests {
    static let kinds: [(String, Backend)] = [
        ("remote", .remote("policy-golden.remote")),
        ("system", .system("policy-golden.system")),
        ("local", .local("policy-golden.local")),
        ("compute", .compute("policy-golden.compute")),
    ]

    @Test func theDerivationTable() {
        var lines: [String] = []
        for (name, backend) in Self.kinds {
            for length in [Backend.Operation.Length.brief, .long] {
                let operation = backend.idempotent("op", length: length)
                for urgency in [Urgency.interactive, .userInitiated, .utility, .background] {
                    lines.append("\(name) \(length) \(operation.policy(at: urgency))")
                }
            }
        }
        let printed = lines.joined(separator: "\n")
        #expect(printed == Self.golden, "\n\(printed)")
    }

    @Test func aReadOnlyOperationTakesNoWriterLane() {
        let store = Backend.local("policy.writers")
        #expect(store.readOnly("load").policy(at: .interactive).writers == nil)
        #expect(store.idempotent("save").policy(at: .interactive).writers == 1)
        #expect(Backend.remote("policy.writers-remote").idempotent("put").policy(at: .interactive).writers == nil)
    }

    @Test func theCeilingCapsThePolicy() {
        let reindex = Backend.local("policy.ceiling").idempotent("reindex", ceiling: .background)
        #expect(reindex.policy(at: .interactive).urgency == .background)
        #expect(reindex.policy(at: .interactive) == reindex.policy(at: .background))
    }

    @Test func declarationsAreValues() {
        let backend = Backend.remote("policy.values", capacity: 3)
        #expect(backend == Backend.remote("policy.values", capacity: 3))
        #expect(backend.description == "remote(policy.values, capacity 3)")
        let fetch = backend.readOnly("fetch")
        #expect(fetch == backend.readOnly("fetch"))
        #expect(fetch != backend.idempotent("fetch"))
        #expect(fetch.description == "policy.values.fetch (readOnly, brief)")
        #expect(Set([fetch, backend.readOnly("fetch")]).count == 1)
    }

    @Test(.failureMode("design/22", "two backends share a name with different kinds, even in different tests"))
    func aConflictingDeclarationIsReportedAndTheFirstWins() async throws {
        let first = await withTestAmbient(clock: TestClock()) { Backend.remote("policy.conflict", capacity: 6) }
        let events = RecordingInstrumentation()
        // Another test, another ambient: the table is the process's.
        let second = SendableBox<Backend?>(nil)
        await withKnownIssue {
            let declared = await withTestAmbient(clock: TestClock(), events: events) { Backend.local("policy.conflict") }
            second.mutate { $0 = declared }
        }
        #expect(first.kind == .remote)
        #expect(second.value?.kind == .remote)
        #expect(second.value?.capacity == 6)
        let reported = try #require(events.events(named: "operation.backend_conflict").first)
        #expect(reported.level == .error)
        #expect(reported.text("backend") == "policy.conflict")
        #expect(reported.text("kind") == "local")
        #expect(reported.number("capacity") == 4)
        // The same declaration again is no conflict.
        let quiet = RecordingInstrumentation()
        _ = await withTestAmbient(clock: TestClock(), events: quiet) { Backend.remote("policy.conflict", capacity: 6) }
        #expect(quiet.events(named: "operation.backend_conflict").isEmpty)
    }

    static let golden = """
        remote brief interactive, deadline 10 s, schedule 2 · 50 ms … 250 ms, attempt timeout 4 s, breaker open 30 s ×2 up to 5 min, 20% jitter, at least 20 calls, admission 6
        remote brief userInitiated, deadline 30 s, schedule 3 · 100 ms … 1 s, attempt timeout 10 s, breaker open 30 s ×2 up to 5 min, 20% jitter, at least 20 calls, admission 5
        remote brief utility, deadline 2 min, schedule 4 · 500 ms … 10 s, attempt timeout 30 s, breaker open 30 s ×2 up to 5 min, 20% jitter, at least 20 calls, admission 4, stretches for device, waits for open breaker
        remote brief background, deadline 10 min, schedule 6 · 1 s … 1 min, attempt timeout 1 min, breaker open 30 s ×2 up to 5 min, 20% jitter, at least 20 calls, admission 3, stretches for device, waits for open breaker
        remote long interactive, deadline 30 s, schedule 2 · 50 ms … 250 ms, attempt timeout none, breaker open 30 s ×2 up to 5 min, 20% jitter, at least 20 calls, admission 6
        remote long userInitiated, deadline 90 s, schedule 3 · 100 ms … 1 s, attempt timeout none, breaker open 30 s ×2 up to 5 min, 20% jitter, at least 20 calls, admission 5
        remote long utility, deadline 6 min, schedule 4 · 500 ms … 10 s, attempt timeout none, breaker open 30 s ×2 up to 5 min, 20% jitter, at least 20 calls, admission 4, stretches for device, waits for open breaker
        remote long background, deadline 30 min, schedule 6 · 1 s … 1 min, attempt timeout none, breaker open 30 s ×2 up to 5 min, 20% jitter, at least 20 calls, admission 3, stretches for device, waits for open breaker
        system brief interactive, deadline 5 s, schedule 2 · 50 ms … 250 ms, attempt timeout 2 s, breaker open 1 s ×2 up to 30 s, 20% jitter, at least 20 calls, admission 4
        system brief userInitiated, deadline 15 s, schedule 3 · 100 ms … 1 s, attempt timeout 5 s, breaker open 1 s ×2 up to 30 s, 20% jitter, at least 20 calls, admission 3
        system brief utility, deadline 1 min, schedule 4 · 500 ms … 10 s, attempt timeout 15 s, breaker open 1 s ×2 up to 30 s, 20% jitter, at least 20 calls, admission 3, stretches for device, waits for open breaker
        system brief background, deadline 5 min, schedule 6 · 1 s … 1 min, attempt timeout 30 s, breaker open 1 s ×2 up to 30 s, 20% jitter, at least 20 calls, admission 2, stretches for device, waits for open breaker
        system long interactive, deadline 15 s, schedule 2 · 50 ms … 250 ms, attempt timeout none, breaker open 1 s ×2 up to 30 s, 20% jitter, at least 20 calls, admission 4
        system long userInitiated, deadline 45 s, schedule 3 · 100 ms … 1 s, attempt timeout none, breaker open 1 s ×2 up to 30 s, 20% jitter, at least 20 calls, admission 3
        system long utility, deadline 3 min, schedule 4 · 500 ms … 10 s, attempt timeout none, breaker open 1 s ×2 up to 30 s, 20% jitter, at least 20 calls, admission 3, stretches for device, waits for open breaker
        system long background, deadline 15 min, schedule 6 · 1 s … 1 min, attempt timeout none, breaker open 1 s ×2 up to 30 s, 20% jitter, at least 20 calls, admission 2, stretches for device, waits for open breaker
        local brief interactive, deadline 2 s, schedule 3 · 10 ms … 100 ms, attempt timeout none, breaker none, admission 4, writers 1
        local brief userInitiated, deadline 10 s, schedule 3 · 10 ms … 100 ms, attempt timeout none, breaker none, admission 3, writers 1
        local brief utility, deadline 1 min, schedule 3 · 10 ms … 100 ms, attempt timeout none, breaker none, admission 3, writers 1, stretches for device
        local brief background, deadline 5 min, schedule 5 · 50 ms … 1 s, attempt timeout none, breaker none, admission 2, writers 1, stretches for device
        local long interactive, deadline 6 s, schedule 3 · 10 ms … 100 ms, attempt timeout none, breaker none, admission 4, writers 1
        local long userInitiated, deadline 30 s, schedule 3 · 10 ms … 100 ms, attempt timeout none, breaker none, admission 3, writers 1
        local long utility, deadline 3 min, schedule 3 · 10 ms … 100 ms, attempt timeout none, breaker none, admission 3, writers 1, stretches for device
        local long background, deadline 15 min, schedule 5 · 50 ms … 1 s, attempt timeout none, breaker none, admission 2, writers 1, stretches for device
        compute brief interactive, deadline 30 s, schedule 2 · 500 ms … 2 s, attempt timeout none, breaker none, admission 1
        compute brief userInitiated, deadline 2 min, schedule 2 · 500 ms … 2 s, attempt timeout none, breaker none, admission 1
        compute brief utility, deadline 10 min, schedule 2 · 500 ms … 2 s, attempt timeout none, breaker none, admission 1, stretches for device
        compute brief background, deadline 30 min, schedule 3 · 5 s … 1 min, attempt timeout none, breaker none, admission 1, stretches for device
        compute long interactive, deadline 90 s, schedule 2 · 500 ms … 2 s, attempt timeout none, breaker none, admission 1
        compute long userInitiated, deadline 6 min, schedule 2 · 500 ms … 2 s, attempt timeout none, breaker none, admission 1
        compute long utility, deadline 30 min, schedule 2 · 500 ms … 2 s, attempt timeout none, breaker none, admission 1, stretches for device
        compute long background, deadline 90 min, schedule 3 · 5 s … 1 min, attempt timeout none, breaker none, admission 1, stretches for device
        """
}
