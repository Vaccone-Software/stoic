#if STOIC_ATTESTATION
import Foundation
import Stoic
@testable import StoicAttestation
import StoicTesting
import Testing

// design/28's ideal scenario, as a test: a volunteer checks in from the app,
// a parent accepts a waiver, a coordinator waits for roles. Who acts is
// verified, when is the service's own clock, and what the device said is
// kept as a claim; the check-in's body comes from a request the stand-in
// signed and the gate verified.

/// Someone the service knows.
private enum Someone: Hashable, Sendable, Codable {
    case volunteer(String), parent(String), staff(String)
}

/// The app's principal evidence: a live session.
private struct Session: PrincipalEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "the request carried a live session token for this person"
    let sessionID: String
}

/// A parent's signed link, another principal evidence.
private struct ParentLink: PrincipalEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "the request carried an unexpired link signed for this parent"
}

private struct AuthError: Error {}

/// Who is asking: the session token, verified. Never a `userId` argument.
private struct Sessions {
    private static let minter = Minter<Session>(Session.Mint())
    private static let links = Minter<ParentLink>(ParentLink.Mint())
    let known: [String: Someone]

    func verify(_ token: Claimed<String>) throws(AuthError) -> Verified<Someone, Session> {
        guard let who = known[Self.minter.read(token)] else { throw AuthError() }
        return Self.minter.verified(who, Session(sessionID: "s-\(Self.minter.read(token))"))
    }

    func verifyLink(_ link: Claimed<String>) throws(AuthError) -> Verified<Someone, ParentLink> {
        guard Self.links.read(link) == "signed-link-p3" else { throw AuthError() }
        return Self.links.verified(.parent("p3"), ParentLink())
    }
}

private enum CheckIn: Permission {
    typealias Subject = String
    typealias Principal = Someone
    static let name = "attendance.check-in"
}

private struct CheckInPolicy: PermissionPolicy {
    typealias Granting = CheckIn
    let name = "own-commitment"
    let owners: [String: Someone]

    func decide(_ who: Verified<Someone, Session>, _ commitment: String) async throws -> PermissionDecision {
        guard let owner = owners[commitment] else { return .deny("no such commitment") }
        return owner == who.value ? .allow : .deny("this is someone else's commitment")
    }
}

private enum EditEvent: Permission {
    typealias Subject = String
    typealias Principal = Someone
    static let name = "events.edit"
}

/// Roles that have not loaded yet.
private struct RolesLoading: PermissionPolicy {
    typealias Granting = EditEvent
    let name = "event-roles"
    func decide(_ who: Verified<Someone, Session>, _ event: String) async throws -> PermissionDecision { .unknown(.loading) }
}

/// One volunteer at one event.
private enum Attendance: Lifecycle {
    static let name = "kindora.attendance"
    typealias Principal = Someone
    enum State: Hashable, Sendable, Codable { case signedUp, onSite(closesAt: Moment), checkedOut }
    enum Event: Hashable, Sendable, Codable { case checkIn(closesAt: Moment), checkOut }
    static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.signedUp, .checkIn(let closesAt)): .to(.onSite(closesAt: closesAt))
        case (.onSite, .checkOut): .to(.checkedOut)
        default: .ignore
        }
    }
    static func timeout(in state: State) -> Self.Timeout? { nil }
    static func isFinal(_ state: State) -> Bool { state == .checkedOut }
}

/// The body the app signs.
private struct CheckInBody: Decodable {
    let commitment: String
    let latitude: Double
    let longitude: Double
    let scannedAt: Claimed<Moment>
}

/// What a waiver's acceptance records.
private struct Accepted: Sendable {
    let at: Moment
    let by: Someone
    let deviceSaid: Claimed<Moment>?
}

/// When: the service's own clock. A waiver's acceptance takes one; a device's moment does not compile.
private func accept(_ waiver: String, at moment: Verified<Moment, OwnClock>, by parent: Verified<Someone, ParentLink>,
                    deviceSaid: Claimed<Moment>?) -> Accepted {
    Accepted(at: moment.value, by: parent.value, deviceSaid: deviceSaid)
}

@Suite("Provenance: the ideal scenario")
struct IdealScenarioTests {
    @Test func checkInWaiverAndAWaitForRolesAsDesign28WritesThem() async throws {
        let rig = try AttestationRig()
        let sessions = Sessions(known: ["token-v7": .volunteer("v7"), "token-c1": .staff("c1")])
        let store = InMemoryLifecycleStore<Attendance, String>()
        let (keyID, challenge) = try await rig.enrolledKey()
        var signing = Signing()
        signing.body = Array(#"{"commitment":"c7","latitude":51.5,"longitude":-0.12,"scannedAt":"2025-12-31T23:00:00Z"}"#.utf8)
        let http = try signing.signed(by: keyID, on: rig.device, nonce: challenge.bytes)

        try await rig.run {
            _ = await store.insert(.new(in: .signedUp, by: .staff("c1"), because: "signed up", at: TestClock.wallClockStart, key: IdempotencyKey(rawValue: "commitment-c7-0123456789")), as: "c7")

            // Who: the session, verified. From where: the gate.
            let me = try sessions.verify(Claimed("token-v7"))
            guard case .attested(let request, _) = try await rig.gate.verify(http, account: "volunteer-7") else {
                Issue.record("not attested")
                return
            }
            let body = try request.deriving { try JSONDecoder().decode(CheckInBody.self, from: Data($0.body)) }
            #expect(body.evidence.counter == 1, "the location is the genuine app's word, and only that")
            // May they: the policy, three answers, a grant in place of an id.
            let commitment = try await CheckInPolicy(owners: ["c7": .volunteer("v7")]).check(Claimed(body.value.commitment), by: me).granted()
            let record = try await store.apply(
                .checkIn(closesAt: TestClock.wallClockStart + .seconds(3600)), to: commitment.value, by: me, because: "checked in from the app")
            #expect(record.written.state == .onSite(closesAt: TestClock.wallClockStart + .seconds(3600)))
            #expect(await store.history(of: "c7").last?.by == .principal(.volunteer("v7")))
            // The device's moment: kept, never trusted.
            #expect(body.value.scannedAt == Claimed(Moment(rfc3339: "2025-12-31T23:00:00Z")!))

            // Someone else's commitment is refused, with the reason to the caller.
            let stranger = try sessions.verify(Claimed("token-c1"))
            let other = try await CheckInPolicy(owners: ["c7": .volunteer("v7")]).check(Claimed("c7"), by: stranger)
            guard case .denied(let denial) = other else { Issue.record("a stranger checked in"); return }
            #expect(denial.reason == "this is someone else's commitment")

            // A waiver: the service's own moment, a verified parent, the device's word beside it.
            let parent = try sessions.verifyLink(Claimed("signed-link-p3"))
            let accepted = accept("w1", at: Moment.stamped(), by: parent, deviceSaid: Claimed(TestClock.wallClockStart - .seconds(86_400)))
            #expect(accepted.at == TestClock.wallClockStart && accepted.by == .parent("p3"))

            // The app, waiting for roles: not "denied", not "allowed".
            let coordinator = try sessions.verify(Claimed("token-c1"))
            switch try await RolesLoading().check(Claimed("event-42"), by: coordinator) {
            case .granted: Issue.record("allowed while loading")
            case .denied: Issue.record("denied while loading")
            case .unknown(let why): #expect(why == .loading)
            }
        }
    }
}
#endif
