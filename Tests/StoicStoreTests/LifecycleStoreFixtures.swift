import Stoic
@testable import StoicStore
import StoicTesting

/// Lodestar's updater, as design/27's second ideal scenario declares it: one
/// record per release, from offer to running or refused, across launches.
enum ReleaseOnThisMac: Lifecycle {
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

/// A notice that is sent, then lapses after a minute: each send owes one
/// effect, each lapse another.
enum Notice: Lifecycle {
    static let name = "test.notice"
    enum State: String, Hashable, Sendable, Codable, CaseIterable { case draft, sent, lapsed, done }
    enum Event: String, Hashable, Sendable, Codable, CaseIterable { case send, lapse, finish }
    enum Effect: Hashable, Sendable, Codable { case mail(String) }
    typealias Principal = String

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.draft, .send), (.lapsed, .send): .to(.sent, effects: [.mail("sent")])
        case (.sent, .lapse): .to(.lapsed, effects: [.mail("lapsed")])
        case (_, .finish): .to(.done)
        default: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? { state == .sent ? .after(.seconds(60), send: .lapse) : nil }
    static func isFinal(_ state: State) -> Bool { state == .done }
}

/// ``Notice`` as a newer build declares it, with a state the older build
/// does not know.
enum NoticeV2: Lifecycle {
    static let name = Notice.name
    static let version = 2
    enum State: String, Hashable, Sendable, Codable, CaseIterable { case draft, sent, lapsed, done, archived }
    typealias Event = Notice.Event
    typealias Effect = Notice.Effect
    typealias Principal = String

    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.done, .finish): .to(.archived)
        case (.draft, .send), (.lapsed, .send): .to(.sent, effects: [.mail("sent")])
        case (_, .finish): .to(.done)
        default: .ignore
        }
    }
}

/// The test clock's wall clock at its start: 2026-01-01T00:00:00Z.
let wallStart = Moment(sinceEpoch: .seconds(1_767_225_600))

typealias NoticeStore = JournaledLifecycleStore<Notice, String>

extension JournaledLifecycleStore {
    /// A store on `disk` at `/d/notices`.
    static func openTest(
        _ disk: SimulatedFileSystem, path: String = "/d/notices", remember: Int = 4_096, threshold: Int = 256 * 1024
    ) async throws -> JournaledLifecycleStore {
        try await open(
            at: path, fileSystem: disk, delivery: DeliveryPolicy(schedule: .immediate.attempts(1)), rememberSettled: remember,
            compactionThreshold: threshold)
    }
}

extension LifecycleRecord {
    /// A record with a key the test names, made at the test's start.
    static func make(_ state: L.State, by: L.Principal, at moment: Moment = wallStart, key: String) -> Self {
        .new(in: state, by: by, because: "made by a test", at: moment, key: IdempotencyKey(rawValue: key))
    }
}

/// A disk with `/d` on it, made durable.
func lifecycleDisk() throws -> SimulatedFileSystem {
    let disk = SimulatedFileSystem()
    try disk.createDirectory("/d")
    disk.settle()
    return disk
}

/// The disk after the process died: a copy holding only what was durable.
/// A copy, because `disk`'s open files belong to the process that died, and
/// a store still holding them must not close descriptors the next one owns.
func afterCrash(_ disk: SimulatedFileSystem) -> SimulatedFileSystem {
    let survivor = disk.fork()
    survivor.crash()
    return survivor
}
