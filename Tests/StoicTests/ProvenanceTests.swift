import Foundation
import Stoic
import StoicTesting
import Testing

/// Editing one of Kindora's events.
private enum EditEvent: Permission {
    typealias Subject = String
    typealias Principal = Someone
    static let name = "events.edit"
}

private struct PolicyFailure: Error {}

/// A policy whose answer the test writes.
private struct ScriptedPolicy: PermissionPolicy {
    typealias Granting = EditEvent
    let name: String
    let answer: @Sendable (Someone, String) async throws -> PermissionDecision

    func decide(_ principal: Verified<Someone, TestPrincipal>, _ subject: String) async throws -> PermissionDecision {
        try await answer(principal.value, subject)
    }
}

/// The coordinator may edit their own event, and nobody else's.
private let coordinatorOwnsE42 = ScriptedPolicy(name: "event-coordinator") { who, event in
    who == .staff("coordinator") && event == "e42" ? .allow : .deny("only the event's coordinator edits it")
}

private let coordinator = TestProof.principal(Someone.staff("coordinator"))

@Suite("Provenance")
struct ProvenanceTests {
    // MARK: Claims and proofs as values

    @Test func printingAClaimOrAProofShowsItsTypeNeverItsValue() throws {
        let email = Claimed("parent@example.com")
        #expect("\(email)" == "Claimed<String>")
        #expect(String(describing: email) == "Claimed<String>")
        #expect(String(reflecting: email) == #"Claimed("parent@example.com")"#, "a debugger sees the value")
        let stamped = Moment.stamped()
        #expect("\(stamped)" == "Verified<Moment> by OwnClock")
        #expect(!"\(TestProof.principal("parent@example.com"))".contains("example.com"))
    }

    @Test func aClaimMapsToAClaimAndComesOutOnlyThroughItsEscape() {
        let typed = Claimed("  e42 ")
        let trimmed = typed.map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(trimmed.unverified() == "e42")
        #expect(trimmed == Claimed("e42"))
    }

    @Test(.failureMode("design/28", "a verified value is encoded and decoded again"))
    func aProofEncodesAsItsValueAndDecodesAsAClaim() async throws {
        let clock = TestClock()
        let stamped = await withTestAmbient(clock: clock) { Moment.stamped() }
        let bytes = try JSONEncoder().encode(stamped)
        #expect(String(decoding: bytes, as: UTF8.self) == #""2026-01-01T00:00:00Z""#, "the value alone")
        let back = try JSONDecoder().decode(Claimed<Moment>.self, from: bytes)
        #expect(back == stamped.claim)
        #expect(try JSONDecoder().decode(Moment.self, from: bytes) == stamped.value)
    }

    @Test(.failureMode("design/28", "a device's moment arrives in a request"))
    func aDevicesMomentIsAClaimKeptBesideTheServicesOwn() async throws {
        struct WaiverBody: Codable { var acceptedAt: Claimed<Moment> }
        struct Accepted { var at: Moment; var deviceSaid: Claimed<Moment> }
        func accept(at moment: Verified<Moment, OwnClock>, deviceSaid: Claimed<Moment>) -> Accepted {
            Accepted(at: moment.value, deviceSaid: deviceSaid)
        }
        let clock = TestClock()
        let body = try JSONDecoder().decode(WaiverBody.self, from: Data(#"{"acceptedAt":"1999-12-31T23:59:59Z"}"#.utf8))
        let accepted = await withTestAmbient(clock: clock) { accept(at: Moment.stamped(), deviceSaid: body.acceptedAt) }
        #expect(accepted.at == TestClock.wallClockStart, "recorded at the service's own moment")
        #expect(accepted.deviceSaid == Claimed(Moment(rfc3339: "1999-12-31T23:59:59Z")!), "the device's word, kept as a claim")
        #expect(try JSONEncoder().encode(body) == Data(#"{"acceptedAt":"1999-12-31T23:59:59Z"}"#.utf8), "the wire format is the value's")
    }

    @Test(.failureMode("design/28", "a stamped moment is read from a clock that is wrong"))
    func aStampedMomentIsTheClocksReadingRightOrWrong() async throws {
        let clock = TestClock()
        let record = Attendance.Record.make(.signedUp(eventEnds: wallStart + day), by: .volunteer("v"))
        clock.jumpWallClock(by: .seconds(-7_200))
        let stamped = await withTestAmbient(clock: clock) { Moment.stamped() }
        #expect(stamped.value == TestClock.wallClockStart - .seconds(7_200), "what the clock read, as the type says")
        // A lifecycle raises an entry dated before its record's latest moment (design/27).
        let change = try record.applying(.withdraw, by: .volunteer("v"), because: "changed plans", at: stamped.value)
        #expect(change.entries.last?.at == record.written.updated, "raised to the record's latest moment")
        #expect(change.clockBehind == .seconds(7_200))
    }

    // MARK: Principals

    @Test(.failureMode("design/28", "a test needs an authenticated principal"))
    func aTestMintsAPrincipalOnRequest() {
        let proof = TestProof.principal(Someone.parent("p1"))
        #expect(proof.value == .parent("p1"))
        #expect(TestPrincipal.proves == "a test said so")
        func needsAnyAuthenticated<E: PrincipalEvidence>(_ principal: Verified<Someone, E>) -> Someone { principal.value }
        #expect(needsAnyAuthenticated(proof) == .parent("p1"))
    }

    @Test(.failureMode("design/28", "a lifecycle event is applied by a verified principal"))
    func aVerifiedPrincipalIsRecordedAsItsValue() async throws {
        try await withTestAmbient(clock: TestClock()) {
            let store = InMemoryLifecycleStore<Attendance, String>()
            _ = await store.insert(.make(.signedUp(eventEnds: wallStart + day), by: .staff("s")), as: "a1")
            let volunteer = TestProof.principal(Someone.volunteer("v7"))
            let record = try await store.apply(
                .checkIn(closesAt: wallStart + hour), to: "a1", by: volunteer, because: "checked in from the app")
            #expect(record.written.state == Attendance.State.onSite(closesAt: wallStart + hour))
            let history = await store.history(of: "a1")
            #expect(history.last?.by == .principal(.volunteer("v7")), "the value, recorded: a record, not a proof")
        }
    }

    // MARK: Permissions

    @Test(.failureMode("design/28", "a policy allows"))
    func anAllowedCheckMintsAGrantOfItsSubject() async throws {
        let events = RecordingInstrumentation()
        let clock = TestClock()
        let check = try await withTestAmbient(clock: clock, events: events) {
            () async throws(CancellationError) -> PermissionCheck<EditEvent> in
            try await coordinatorOwnsE42.check(Claimed("e42"), by: coordinator)
        }
        guard case .granted(let grant) = check else { Issue.record("not granted: \(check)"); return }
        #expect(grant.value == "e42", "the subject is the proof's value: an action takes it in place of an id")
        #expect(grant.evidence.principal == .staff("coordinator"))
        #expect(grant.evidence.policy == "event-coordinator")
        #expect(grant.evidence.decidedAt == TestClock.wallClockStart)
        #expect(Grant<EditEvent>.proves.contains("events.edit"))
        let event = try #require(events.events(named: "permission.granted").first)
        #expect(event.level == .debug)
        #expect(event.label == "events.edit")
        #expect(event["policy"]?.description == "event-coordinator")
        #expect(event.fields.first { $0.key == "subject" }?.privacy == .private)
        #expect(event.fields.first { $0.key == "principal" }?.privacy == .private)
        #expect(event["duration"] != nil)
        #expect(try check.granted() == grant)
    }

    @Test(.failureMode("design/28", "a policy denies"))
    func aDeniedCheckCarriesTheReasonToTheCallerAndNeverToAnEvent() async throws {
        let events = RecordingInstrumentation()
        let volunteer = TestProof.principal(Someone.volunteer("v7"))
        let check = try await withTestAmbient(clock: TestClock(), events: events) {
            () async throws(CancellationError) -> PermissionCheck<EditEvent> in
            try await coordinatorOwnsE42.check(Claimed("e42"), by: volunteer)
        }
        guard case .denied(let denial) = check else { Issue.record("not denied: \(check)"); return }
        #expect(denial.reason == "only the event's coordinator edits it")
        #expect(denial.subject == "e42" && denial.principal == .volunteer("v7") && denial.policy == "event-coordinator")
        let event = try #require(events.events(named: "permission.denied").first)
        #expect(event.level == .info)
        #expect(!event.description.contains("coordinator edits"), "a reason can name a person")
        #expect(throws: PermissionRefusal<EditEvent>.denied(denial)) { try check.granted() }
        #expect(PermissionRefusal<EditEvent>.denied(denial).retryDecision == .stop, "a 403")
    }

    @Test(.failureMode("design/28", "a check's policy has not loaded"))
    func aPolicyStillLoadingIsUnknownNeitherDeniedNorAllowed() async throws {
        let events = RecordingInstrumentation()
        let loading = ScriptedPolicy(name: "roles") { _, _ in .unknown(.loading) }
        let check = try await withTestAmbient(clock: TestClock(), events: events) {
            () async throws(CancellationError) -> PermissionCheck<EditEvent> in
            try await loading.check(Claimed("e42"), by: coordinator)
        }
        guard case .unknown(.loading) = check else { Issue.record("not loading: \(check)"); return }
        let event = try #require(events.events(named: "permission.unknown").first)
        #expect(event.level == .notice)
        #expect(event["unknown"]?.description == "loading")
        #expect(throws: PermissionRefusal<EditEvent>.unknown(.loading)) { try check.granted() }
        #expect(PermissionRefusal<EditEvent>.unknown(.loading).retryDecision == .retry, "a 503, never a 403")
    }

    @Test(.failureMode("design/28", "a policy throws"))
    func aThrowingPolicyIsUnavailableWithItsErrorsType() async throws {
        let events = RecordingInstrumentation()
        let broken = ScriptedPolicy(name: "roles") { _, _ in throw PolicyFailure() }
        let check = try await withTestAmbient(clock: TestClock(), events: events) {
            () async throws(CancellationError) -> PermissionCheck<EditEvent> in
            try await broken.check(Claimed("e42"), by: coordinator)
        }
        guard case .unknown(.unavailable(let why)) = check else { Issue.record("not unavailable: \(check)"); return }
        #expect(why.hasSuffix("PolicyFailure"))
        let event = try #require(events.events(named: "permission.unknown").first)
        #expect(event.level == .notice)
        #expect(event["unknown"]?.description == "unavailable")
        #expect(event["error"]?.description.hasSuffix("PolicyFailure") == true)
        #expect(event.fields.first { $0.key == "error" }?.privacy == .public)
        do throws(PermissionRefusal<EditEvent>) {
            _ = try check.granted()
            Issue.record("an unknown answer granted")
        } catch {
            #expect(error.retryDecision == .retry)
            #expect(error.retryDecision != .stop, "never sent as a refusal")
        }
    }

    @Test(.failureMode("design/28", "the caller is cancelled during a check"))
    func aCancelledCallerGetsCancellationAndNoOutcomeIsReported() async throws {
        let events = RecordingInstrumentation()
        let clock = TestClock()
        let asked = SendableBox(0)
        let slow = ScriptedPolicy(name: "roles") { _, _ in
            asked.mutate { $0 += 1 }
            try await Ambient.sleep(for: .seconds(30))
            return .allow
        }
        // Cancelled during `decide`.
        let during = Task {
            try await withTestAmbient(clock: clock, events: events) { () async throws(CancellationError) -> PermissionCheck<EditEvent> in
                try await slow.check(Claimed("e42"), by: coordinator)
            }
        }
        await clock.waitForSleepers(count: 1)
        during.cancel()
        await #expect(throws: CancellationError.self) { try await during.value }
        // Cancelled before it starts: the policy is never asked.
        let before = await withTaskGroup(of: Bool.self) { group in
            group.cancelAll()
            group.addTask {
                do {
                    _ = try await withTestAmbient(clock: clock, events: events) {
                        () async throws(CancellationError) -> PermissionCheck<EditEvent> in
                        try await slow.check(Claimed("e42"), by: coordinator)
                    }
                    return false
                } catch {
                    return true
                }
            }
            return await group.next() ?? false
        }
        #expect(before, "a check started cancelled throws CancellationError")
        #expect(asked.value == 1, "a cancelled check does not ask the policy")
        #expect(events.events.filter { $0.name.rawValue.hasPrefix("permission.") }.isEmpty)
    }

    @Test(.failureMode("design/28", "a grant for one subject is used to act on another"))
    func anActionTakesTheGrantAsItsTarget() async throws {
        func edit(_ grant: Granted<EditEvent>) -> String { "edited \(grant.value)" }
        let check = try await withTestAmbient(clock: TestClock()) { () async throws(CancellationError) -> PermissionCheck<EditEvent> in
            try await coordinatorOwnsE42.check(Claimed("e42"), by: coordinator)
        }
        #expect(edit(try check.granted()) == "edited e42", "the only id the action has is the one the grant proves")
    }

    @Test(.failureMode("design/28", "a grant made on a device is sent to the server"))
    func aGrantSentAcrossArrivesAsAClaimAndIsCheckedAgain() async throws {
        let device = try await withTestAmbient(clock: TestClock()) { () async throws(CancellationError) -> PermissionCheck<EditEvent> in
            try await coordinatorOwnsE42.check(Claimed("e42"), by: coordinator)
        }
        let sent = try JSONEncoder().encode(try device.granted())
        #expect(String(decoding: sent, as: UTF8.self) == #""e42""#, "only the subject's id")
        let arrived = try JSONDecoder().decode(Claimed<String>.self, from: sent)
        let serverPolicy = ScriptedPolicy(name: "server-roles") { _, _ in .deny("the coordinator was replaced") }
        let server = try await withTestAmbient(clock: TestClock()) { () async throws(CancellationError) -> PermissionCheck<EditEvent> in
            try await serverPolicy.check(arrived, by: coordinator)
        }
        guard case .denied = server else { Issue.record("the server took the device's grant: \(server)"); return }
    }

    @Test(.failureMode("design/28", "a permission is revoked while a grant is held"))
    func aHeldGrantStaysARecordOfItsDecision() async throws {
        let clock = TestClock()
        let revoked = SendableBox(false)
        let policy = ScriptedPolicy(name: "event-coordinator") { _, _ in revoked.value ? .deny("revoked") : .allow }
        let first = try await withTestAmbient(clock: clock) { () async throws(CancellationError) -> PermissionCheck<EditEvent> in
            try await policy.check(Claimed("e42"), by: coordinator)
        }
        let held = try first.granted()
        await clock.advance(by: .seconds(60))
        revoked.mutate { $0 = true }
        let second = try await withTestAmbient(clock: clock) { () async throws(CancellationError) -> PermissionCheck<EditEvent> in
            try await policy.check(Claimed("e42"), by: coordinator)
        }
        guard case .denied = second else { Issue.record("still granted after revocation"); return }
        #expect(held.evidence.decidedAt == TestClock.wallClockStart, "a true record of the decision when it was made")
    }
}
