import Stoic
import StoicStore
import StoicTesting

// The formats Stoic's store compatibility fixtures hold (design/32), as
// 0.7.0 recorded them in Compatibility/. The definitions and the scenario
// that wrote them are part of the fixtures: they change only with them,
// never to make a reading pass.

/// A release on a Mac, as Lodestar keeps one (design/27's second scenario).
enum CompatRelease: Lifecycle {
    static let name = "lodestar.release"
    enum Principal: Hashable, Sendable, Codable { case updater, successor(pid: Int32), watchdog, person }

    enum State: String, Hashable, Sendable, Codable, CaseIterable {
        case offered, downloading, staged, applying, running, rolledBack, refused
    }
    enum Event: String, Hashable, Sendable, Codable, CaseIterable {
        case download, verified, failed, stall, apply, confirm, rollBack, unchanged
    }
    enum Effect: Hashable, Sendable, Codable { case announce(State) }

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.offered, .download): .to(.downloading)
        case (.downloading, .verified): .to(.staged)
        case (.downloading, .failed), (.downloading, .stall): .to(.offered)
        case (.staged, .apply): .to(.applying)
        case (.applying, .confirm): .to(.running, effects: [.announce(.running)])
        case (.applying, .rollBack), (.applying, .stall): .to(.rolledBack, effects: [.announce(.rolledBack)])
        case (.applying, .unchanged): .to(.refused, effects: [.announce(.refused)])
        case (.rolledBack, _), (.refused, _): .refuse("this release failed its handover once")
        default: .ignore
        }
    }

    static func timeout(in state: State) -> Self.Timeout? {
        switch state {
        case .downloading: .after(.seconds(30 * 60), send: .stall)
        case .applying: .after(.seconds(120), send: .stall)
        default: nil
        }
    }

    static func isFinal(_ state: State) -> Bool { [.running, .rolledBack, .refused].contains(state) }
}

/// A message an outbox delivers.
struct CompatMessage: Codable, Sendable, Equatable {
    var to: String
    var body: String
}

/// What 0.7.0 did to write `lifecycle.journal` and the records and entries
/// in it: one release updated and confirmed, one whose download stalled,
/// its timeout settled. Deterministic: virtual time and fixed keys.
func recordReleases(at path: String, on disk: SimulatedFileSystem) async throws {
    let clock = TestClock()
    try await withTestAmbient(clock: clock) {
        let store = try await JournaledLifecycleStore<CompatRelease, String>.open(
            at: path, fileSystem: disk, delivery: DeliveryPolicy(schedule: .immediate.attempts(1)))
        _ = try await store.insert(
            .new(in: .offered, by: .updater, because: "the feed offered 0.56", at: TestClock.wallClockStart,
                 key: IdempotencyKey(rawValue: "release-0.56")), as: "0.56")
        try await store.apply(.download, to: "0.56", by: .person, because: "the person chose to update")
        await clock.advance(by: .seconds(40))
        try await store.apply(.verified, to: "0.56", by: .updater, because: "the digest matched")
        try await store.apply(.apply, to: "0.56", by: .updater, because: "relaunching into 0.56")
        await clock.advance(by: .seconds(3))
        try await store.apply(.confirm, to: "0.56", by: .successor(pid: 4_242), because: "the router answered 1.2 s after launch")
        _ = try await store.insert(
            .new(in: .offered, by: .updater, because: "the feed offered 0.55", at: Moment.now,
                 key: IdempotencyKey(rawValue: "release-0.55")), as: "0.55")
        try await store.apply(.download, to: "0.55", by: .updater, because: "an automatic update")
        await clock.advance(by: .seconds(31 * 60))
        try await store.settleDue()
        try await store.close()
    }
}
