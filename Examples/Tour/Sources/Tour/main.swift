import Stoic
import StoicJSON
import StoicSchema
import Synchronization

// Every Stoic decision in this tour is printed as it happens.
struct PrintEvents: Instrumentation {
    func record(_ event: Event) {
        print("    · \(event.name)\(event.label.map { " [\($0)]" } ?? "") \(event.fields.map(\.description).joined(separator: " "))")
    }
}

struct Flaky: Error, Retryable {
    var retryDecision: RetryDecision { .retry }
}

/// A dependency that fails its first `failures` calls.
final class Server: Sendable {
    private let calls = Mutex(0)
    let failures: Int
    init(failures: Int) { self.failures = failures }
    func fetch() async throws(Flaky) -> String {
        let call = calls.withLock { $0 += 1; return $0 }
        try? await Task.sleep(for: .milliseconds(20))
        if call <= failures { throw Flaky() }
        return "profile #\(call)"
    }
}

func section(_ title: String) { print("\n▸ \(title)") }

try await withAmbient({ $0.instrumentation = PrintEvents() }) {
    section("retry: a bounded, jittered, budgeted policy")
    let server = Server(failures: 2)
    let profile = try await retry(.exponential(base: .milliseconds(50)).attempts(5), label: "fetch profile") { _ throws(Flaky) in
        try await server.fetch()
    }
    print("  got \(profile)")

    section("withTimeout: the work is cancelled, with a cause")
    do {
        try await withTimeout(.milliseconds(100), label: "slow call") {
            do { try await Task.sleep(for: .seconds(10)) } catch {
                print("  cancelled because: \(CancellationCause.current?.rawValue ?? "?")")
                throw error
            }
        }
    } catch {
        print("  threw \(type(of: error))")
    }

    section("withScope: release in reverse, even on failure")
    do {
        try await withScope { (scope: borrowing Scope) throws(Flaky) in
            _ = await scope.acquire({ "socket" }, release: { name, exit in print("  released \(name) (\(exit.isFailure ? "failure" : "success"))") })
            _ = await scope.acquire({ "file" }, release: { name, _ in print("  released \(name)") })
            throw Flaky()
        }
    } catch {
        print("  body's error passed through: \(type(of: error))")
    }

    section("StateMachine: work belongs to a state")
    enum Phase: Hashable, Sendable { case idle, listening, done }
    enum Input: Sendable { case start, heard, stop }
    let machine = StateMachine<Phase, Input>(initial: .idle, label: "dictation") { phase, input in
        switch (phase, input) {
        case (.idle, .start): .to(.listening)
        case (.listening, .heard): .to(.done)
        case (_, .stop): .to(.idle)
        default: .ignore
        }
    }
    machine.whileIn(.listening, label: "microphone") { sender in
        try? await Task.sleep(for: .milliseconds(30))
        sender.send(.heard)
    }
    machine.send(.start)
    try await Task.sleep(for: .milliseconds(100))
    print("  state: \(machine.state); history: \(machine.history.map { "\($0.from)→\($0.to)" })")

    section("Supervisor: restart, then escalate when restarting stops helping")
    let supervisor = Supervisor(label: "app", intensity: .init(maxRestarts: 2, within: .seconds(5)), backoff: .fixed(.milliseconds(20))) {
        Child("sync") { _ in throw Flaky() }
    }
    do { try await supervisor.run() } catch let escalation as SupervisorEscalation {
        print("  \(escalation)")
    }

    section("StoicSchema: every problem, with its line and a suggestion")
    struct Settings: Sendable, Equatable {
        var scrollSpeed = 1200.0
        var hosts: [String] = []
        static let schema = Schema.object(Settings.self, default: Settings()) {
            Field("scrollSpeed", \.scrollSpeed, .double(.range(200...4000)), doc: "Pixels per second.")
            Field("hosts", \.hosts, .array(of: .string(.length(1...253)), count: 0...4))
        }
    }
    let text = """
        {
          "scrolSpeed": 1500,
          "hosts": ["a.example", "", "c.example"],
          "scrollSpeed": 9000
        }
        """
    do {
        _ = try Settings.schema.decode(text)
    } catch {
        print("\(error)".split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
    }
}
print("\nDone.")
