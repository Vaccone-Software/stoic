import Stoic
@testable import StoicLive
import StoicTesting
import Synchronization
import Testing

/// design/31's ideal scenario, as a test: a volunteering app's event screen,
/// its roster joined by email, its edit permission, a sign-up that is one
/// commitment however often it is tapped, and a delete that takes the proof.
@Suite("Live: the event screen")
@MainActor
struct LiveScenarioTests {
    struct Attendee: Sendable { let email: String; let name: String }
    struct MinorStatus: Sendable { let email: String; let isMinor: Bool }
    struct RosterRow: Sendable, Equatable { let name: String; let minor: Bool? }

    enum EditEvent: Permission {
        typealias Subject = String
        typealias Principal = String
        static let name = "kindora.edit-event"
    }

    /// The server: attendees, minors, and commitments deduplicated by key.
    final class Server: Sendable {
        private let state = Mutex((attendees: ["ana@x"], minors: [String](), commitments: [IdempotencyKey: String](), deleted: 0))
        let permissions = TestGate()
        let signUpGate = TestGate()

        func attendees() -> [Attendee] {
            state.withLock { $0.attendees.map { Attendee(email: $0, name: String($0.prefix(3))) } }
        }

        func minors() -> [MinorStatus] {
            state.withLock { $0.minors.map { MinorStatus(email: $0, isMinor: true) } }
        }

        func signUp(_ email: String, key: IdempotencyKey) async {
            await signUpGate.wait()
            state.withLock { state in
                guard state.commitments[key] == nil else { return }   // the server deduplicates by key
                state.commitments[key] = email
                state.attendees.append(email)
                state.minors.append(email)
            }
        }

        var commitments: Int { state.withLock { $0.commitments.count } }
        var deletes: Int { state.withLock { $0.deleted } }
        func delete() { state.withLock { $0.deleted += 1 } }
    }

    @MainActor final class EventScreen {
        let roster: Live<[RosterRow]>
        let attendees: Live<[Attendee]>
        let minors: Live<[MinorStatus]>
        let canEdit: Live<PermissionCheck<EditEvent>>
        let signUp: Action<String, Void>
        let delete: Action<Granted<EditEvent>, Void>

        init(server: Server, me: String) {
            attendees = Live(API.roster, freshFor: .seconds(30)) { _ in server.attendees() }
            minors = Live(API.minors) { _ in server.minors() }
            roster = .joining(attendees, minors, on: \.email, \.email) { attendee, minor in
                RosterRow(name: attendee.name, minor: minor?.isMinor)   // nil: not in the answer, shown as "unknown", never "No"
            }
            canEdit = Live(API.roles) { _ in
                await server.permissions.wait()
                return try await Organisers().check(Claimed("beach-clean"), by: Session.verified(me))
            }
            signUp = Action(API.signUp, whileRunning: .join, refreshes: [attendees, minors]) { email, attempt in
                await server.signUp(email, key: attempt.idempotencyKey)   // one key per intent
            }
            delete = Action(API.remove) { (_: Granted<EditEvent>, _: Attempt) async throws(Refused) in server.delete() }
        }
    }

    struct Session: PrincipalEvidence {
        struct Mint { fileprivate init() {} }
        static let proves = "a signed-in session"
        static func verified(_ who: String) -> Verified<String, Session> { Minter<Session>(Mint()).verified(who, Session()) }
    }

    struct Organisers: PermissionPolicy {
        typealias Granting = EditEvent
        typealias Authentication = Session
        let name = "organisers"
        nonisolated(nonsending) func decide(_ principal: Verified<String, Session>, _ subject: String) async throws -> PermissionDecision {
            principal.value == "organiser@x" ? .allow : .deny("only the organiser edits")
        }
    }

    @Test func theRosterStaysConsistentASignUpIsOneCommitmentAndDeleteWaitsForTheProof() async throws {
        try await onLiveTime { _, _ in
            let server = Server()
            let screen = EventScreen(server: server, me: "organiser@x")
            await until { screen.roster.phase.value != nil }
            #expect(screen.roster.phase == .fresh([RosterRow(name: "ana", minor: nil)]), "unknown, never \"not a minor\"")

            // A delete cannot be triggered while the permissions load: there is no proof.
            guard case .unknown(.loading) = screen.canEdit.check() else { Issue.record("\(screen.canEdit.check())"); return }

            // A double tap: one request, one key, one commitment.
            #expect(screen.signUp.trigger("ben@x") == .started)
            #expect(screen.signUp.trigger("ben@x") == .joined)
            server.signUpGate.open()
            await screen.signUp.waitForEnd()
            #expect(server.commitments == 1)
            // Both lists refresh together; the roster never shows one new list beside an old one.
            #expect(screen.roster.phase == .stale([RosterRow(name: "ana", minor: nil)], refreshing: false))
            await until { screen.roster.phase.value?.count == 2 }
            #expect(screen.roster.phase == .fresh([RosterRow(name: "ana", minor: nil), RosterRow(name: "ben", minor: true)]))

            // The permissions arrive: the proof exists, and only then can delete be triggered.
            server.permissions.open()
            await until { if case .granted = screen.canEdit.check() { true } else { false } }
            guard case .granted(let proof) = screen.canEdit.check() else { return }
            _ = await screen.delete.run(proof)
            #expect(server.deletes == 1)
        }
    }
}
