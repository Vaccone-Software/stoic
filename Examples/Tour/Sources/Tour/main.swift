import Foundation
import Stoic
import StoicJSON
import StoicSchema
import StoicSettings
import StoicStore
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
    func fetch() async throws -> String {
        let call = calls.withLock { $0 += 1; return $0 }
        try await Ambient.sleep(for: .milliseconds(20))
        if call <= failures { throw Flaky() }
        return "profile #\(call)"
    }
}

func section(_ title: String) { print("\n▸ \(title)") }

/// A call that outlives its timeout: the work is cancelled, with a cause, and
/// the call ends in the cancellation its work threw.
func slowCall() async throws {
    do {
        try await withTimeout(.milliseconds(100), label: "slow call") {
            do { try await Ambient.sleep(for: .seconds(10)) } catch {
                print("  cancelled because: \(CancellationCause.current?.rawValue ?? "?")")
                throw error
            }
        }
    } catch is CancellationError {
        print("  threw CancellationError")
    }
}

// What the app depends on, declared once: facts, and no numbers.
extension Backend {
    static let catalogue = Backend.remote("catalogue")
    static let payments = Backend.remote("payments")
}
enum Catalogue { static let episode = Backend.catalogue.readOnly("episode") }
enum Payments { static let subscribe = Backend.payments.keyed("subscribe") }

try await withAmbient({ $0.instrumentation = PrintEvents() }) {
    section("retry: a bounded, jittered, budgeted policy")
    let server = Server(failures: 2)
    let profile = try await retry(.exponential(base: .milliseconds(50)).attempts(5), label: "fetch profile") { _ in
        try await server.fetch()
    }
    print("  got \(profile)")

    section("Operations: say what it is and who waits; the numbers are derived")
    for urgency in [Urgency.interactive, .background] {  // the same call, who is waiting differs
        print("  \(Catalogue.episode.policy(at: urgency))")
    }
    let catalogue = Server(failures: 1)
    let episode = try await withUrgency(.interactive) {
        try await Catalogue.episode.perform { _ throws(Flaky) in try await catalogue.fetch() }
    }
    print("  a tap got \(episode)")
    // The payment reaches the server and then the connection is lost: it
    // is retried under one key, and the error says it may have been charged.
    let checkout = IdempotencyKey.random()
    do {
        _ = try await withUrgency(.interactive) { () throws(OperationError<Flaky>) in
            try await Payments.subscribe.perform(idempotencyKey: checkout) { attempt throws(Flaky) in
                print("  charging under \(attempt.idempotencyKey) (attempt \(attempt.number))")
                throw Flaky()
            }
        }
    } catch let error as OperationError<Flaky> {
        print("  outcome: \(error.outcome): reconcile under \(checkout), never ask again")
    }

    section("withTimeout: the work is cancelled, with a cause")
    try await slowCall()

    section("withScope: release in reverse, even on failure")
    do {
        try await withScope { (scope: borrowing Scope) throws(Flaky) in
            _ = await scope.acquire({ "socket" }, release: { name, exit in print("  released \(name) (\(exit.isFailure ? "failure" : "success"))") })
            _ = await scope.acquire({ "file" }, release: { name, _ in print("  released \(name)") })
            throw Flaky()
        }
    } catch let flaky as Flaky {
        print("  body's error passed through: \(type(of: flaky))")
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
        do { try await Ambient.sleep(for: .milliseconds(30)) } catch { return }   // left the state: cancelled
        sender.send(.heard)
    }
    machine.send(.start)
    try await Ambient.sleep(for: .milliseconds(100))
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
        _ = try Settings.schema.decode(text) { warning in print("  warning: \(warning)") }
    } catch let failure as ValidationFailure {
        print("\(failure)".split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
    }

    // The files these sections write go when the scope ends, however it ends.
    try await withScope(label: "tour files") { scope in
        let directory = try await scope.acquire(label: "tour directory", {
            let path = FileManager.default.temporaryDirectory.appending(path: "stoic-tour-\(UUID().uuidString)").path()
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }, release: { path, _ in try FileManager.default.removeItem(atPath: path) })

        section("SettingsStore: validated, crash-safe, and an older build cannot ruin it")
        let settings = try SettingsStore.open(at: directory + "/settings.json", schema: Settings.schema)
        print("  first launch: \(settings.value.scrollSpeed) from \(settings.source)")
        try settings.update { $0.scrollSpeed = 900 }
        do {
            try settings.update { $0.scrollSpeed = 99_999 }
        } catch SettingsStore<Settings>.UpdateError.invalid(let issues) {
            print("  refused: \(issues.map(\.description).joined(separator: "; "))")
        }
        let reopened = try SettingsStore.open(at: directory + "/settings.json", schema: Settings.schema)
        print("  next launch: \(reopened.value.scrollSpeed) from \(reopened.source)")

        section("FlightRecorder: the next launch reads what this one was doing")
        do {
            let recorder = try FlightRecorder(path: directory + "/flight.rec", capacity: 64 * 1024)
            recorder.record(Event("tour.sync_started", level: .info, label: "sync"))
            recorder.record(Event("tour.retrying", level: .warning, label: "sync", fields: [.init("attempt", .int(2))]))
            // …and the process dies here, without markCleanExit().
        }
        let recorder = try FlightRecorder(path: directory + "/flight.rec", capacity: 64 * 1024)
        if let last = recorder.previousRun {
            print("  previous run ended cleanly: \(last.endedCleanly); its last events:")
            for event in last.events { print("    \(event)") }
        }
    }

    section("Quarantine: never close a handle a wedged call may still be using")
    try await withScope { scope in
        scope.onExit(label: "close audio handle", ifWorkAbandoned: .quarantine) { _ in print("  closed the handle") }
        do {
            _ = try await abandoningAfter(.milliseconds(50), label: "tour.audio") { () throws(Flaky) -> Int in
                Thread.sleep(forTimeInterval: 0.2)   // a call that ignores every deadline
                return 1
            }
        } catch let error as PolicyError<Flaky> {
            print("  stopped waiting: \(error)")
        }
        print("  abandoned work in this scope: \(scope.abandonedWork)")
    }
}
print("\nDone.")
