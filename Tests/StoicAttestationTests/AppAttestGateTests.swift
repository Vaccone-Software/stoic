#if STOIC_ATTESTATION
import Foundation
import Stoic
@testable import StoicAttestation
import StoicTesting
import Synchronization
import Testing

@Suite("App Attest: the gate")
struct AppAttestGateTests {
    // MARK: Enrolment

    @Test func aKeyEnrolsAndItsRecordIsKept() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        #expect(challenge.lifetime == .seconds(300))
        let record = try #require(await rig.ledger.records.first)
        #expect(Base64.encode(record.key.id) == keyID && record.account == "volunteer-7" && record.revision == 1)
        #expect(record.counter == .enrolled)
        #expect(rig.events.events(named: "attest.server_enrolled").first?["repeated"]?.description == "false")
    }

    @Test(.failureMode("design/29", "an attestation is replayed to enrol its key again"),
          .failureMode("design/29", "the enrolment's response is lost"))
    func theSameEnrolmentAgainIsAnsweredAsTheSameAndResetsNothing() async throws {
        let rig = try AttestationRig()
        let (keyID, enrolment) = try await rig.attestedKey()
        _ = try await rig.enrol(enrolment).get()
        let first = Signing()
        let challenge = await rig.run { rig.gate.challenge(.requests) }
        _ = try await rig.verify(try first.signed(by: keyID, on: rig.device, nonce: challenge.bytes)).get()
        let before = try #require(await rig.ledger.records.first)
        #expect(before.counter.highest == 1)
        _ = try await rig.enrol(enrolment).get()
        let after = try #require(await rig.ledger.records.first)
        #expect(after == before, "the counter is not reset")
        #expect(rig.events.events(named: "attest.server_enrolled").last?["repeated"]?.description == "true")
        #expect(await rig.enrol(enrolment, account: "someone-else") == .failure(AppAttestRefusal(code: "key_enrolled", cause: "key_enrolled", challenge: nil)),
                "the same attestation for another account is not the same enrolment")
    }

    @Test(.failureMode("design/29", "a key id already on record arrives with another attestation"))
    func aKeyIdOnRecordWithAnotherAttestationIsRefused() async throws {
        let rig = try AttestationRig()
        let (keyID, enrolment) = try await rig.attestedKey()
        _ = try await rig.enrol(enrolment).get()
        let other = AppAttestEnrolment(keyID: keyID, attestation: enrolment.attestation + [0], challenge: enrolment.challenge)
        #expect(await rig.enrol(other).refusal == "key_enrolled")
    }

    @Test(.failureMode("design/29", "an enrolment challenge is used twice"))
    func anEnrolmentChallengeIsSingleUse() async throws {
        let rig = try AttestationRig()
        let challenge = await rig.run { rig.gate.challenge(.enrolment) }
        func enrolment() throws -> AppAttestEnrolment {
            let key = rig.device.generateKey()
            return AppAttestEnrolment(key: key, attestation: try rig.device.attest(key, clientDataHash: sha256(challenge.bytes)), challenge: challenge.bytes)
        }
        _ = try await rig.enrol(try enrolment()).get()
        let second = await rig.enrol(try enrolment())
        #expect(second.refusal == "challenge_used")
        #expect(second.status == 422)
    }

    @Test(.failureMode("design/29", "a key from another app id is presented"))
    func aKeyOfAnotherAppIsRefusedAtEnrolmentAndPerRequest() async throws {
        let rig = try AttestationRig()
        var attesting = AppAttestStandIn.Attesting()
        attesting.app = try AppID("ZZZZZZZZZZ.com.other")
        let (_, enrolment) = try await rig.attestedKey(attesting)
        let refused = await rig.enrol(enrolment)
        #expect(refused.refusal == "invalid_attestation")
        #expect(rig.events.events(named: "attest.attestation_refused").last?["check"]?.description == "app_id")
        // Per request: an assertion carrying another app id's hash.
        let (keyID, challenge) = try await rig.enrolledKey()
        var signing = Signing()
        signing.app = attesting.app
        let request = try signing.signed(by: keyID, on: rig.device, nonce: challenge.bytes)
        #expect(await rig.verify(request).refusal == "invalid")
        #expect(rig.events.events(named: "attest.assertion_refused").last?["check"]?.description == "app_id")
    }

    @Test(.failureMode("design/29", "a development key is presented to production (or the reverse)"))
    func aDevelopmentKeyIsRefusedByProduction() async throws {
        let rig = try AttestationRig()
        var attesting = AppAttestStandIn.Attesting()
        attesting.environment = .development
        let (_, enrolment) = try await rig.attestedKey(attesting)
        #expect(await rig.enrol(enrolment).refusal == "environment")
    }

    @Test(.failureMode("design/29", "the certificate chain does not lead to the root at the server's moment"))
    func aChainToAnotherRootOrAnExpiredCredentialIsRefused() async throws {
        let rig = try AttestationRig()
        let stranger = try AppAttestStandIn(app: kindora, at: TestClock.wallClockStart)
        let challenge = await rig.run { rig.gate.challenge(.enrolment) }
        let key = stranger.generateKey()
        let foreign = AppAttestEnrolment(key: key, attestation: try stranger.attest(key, clientDataHash: sha256(challenge.bytes)), challenge: challenge.bytes)
        #expect(await rig.enrol(foreign).cause == "chain")
        var expired = AppAttestStandIn.Attesting()
        expired.validity = (TestClock.wallClockStart - .seconds(5 * 86_400))...(TestClock.wallClockStart - .seconds(2 * 86_400))
        let (_, old) = try await rig.attestedKey(expired)
        let refused = await rig.enrol(old)
        #expect(refused.cause == "chain")
        #expect(refused.refusal == "invalid_attestation")
    }

    @Test(.failureMode("design/29", "the credential certificate's nonce is not the one for this challenge and data"),
          .failureMode("design/29", "the key id is not the certified key's hash"),
          .failureMode("design/29", "the attestation's counter is not zero"))
    func everyAttestationCheckHasItsOwnFailure() async throws {
        let rig = try AttestationRig()
        func failure(_ change: (inout AppAttestStandIn.Attesting) -> Void, keyID: ((String) -> String)? = nil) async throws -> AttestationFailure? {
            var attesting = AppAttestStandIn.Attesting()
            change(&attesting)
            let challenge = Array("an enrolment challenge".utf8)
            let key = rig.device.generateKey()
            let object = try rig.device.attest(key, clientDataHash: sha256(challenge), attesting)
            do throws(AttestationFailure) {
                _ = try await AppAttest.verifyAttestation(
                    object, keyID: keyID?(key) ?? key, challenge: challenge, app: kindora, environment: .production, root: rig.device.root,
                    at: TestClock.wallClockStart)
                return nil
            } catch {
                return error
            }
        }
        #expect(try await failure { _ in } == nil)
        #expect(try await failure { $0.wrongNonce = true } == .nonceMismatch)
        #expect(try await failure({ _ in }, keyID: { _ in Base64.encode(Array(repeating: 9, count: 32)) }) == .keyIDMismatch)
        #expect(try await failure { $0.otherCredentialID = true } == .keyIDMismatch)
        #expect(try await failure { $0.counter = 1 } == .counterNotZero)
        #expect(try await failure { $0.extraCertificate = true } == .malformed("x5c is not two certificates"))
        #expect(try await failure({ _ in }, keyID: { _ in "not base64" }) == .malformed("the key id is not 32 bytes of canonical base64"))
    }

    // MARK: Challenges at the gate

    @Test(.failureMode("design/29", "a request challenge expires"))
    func anExpiredRequestChallengeIsStaleWithAFreshOne() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        await rig.clock.advance(by: .seconds(301))
        let refused = await rig.verify(try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes))
        guard case .failure(let refusal) = refused else { Issue.record("an expired challenge verified"); return }
        #expect(refusal.code == "stale_challenge" && refusal.status == 401)
        let fresh = try #require(refusal.challenge)
        #expect(rig.gate.headers(for: refusal).map(\.name) == ["WWW-Authenticate", "App-Attest-Challenge"])
        #expect(rig.gate.headers(for: refusal).first?.value == #"AppAttest error="stale_challenge""#)
        #expect(rig.events.events(named: "attest.assertion_refused").last?.level == .debug, "a stale challenge is routine")
        _ = try await rig.verify(try Signing().signed(by: keyID, on: rig.device, nonce: fresh.bytes)).get()
    }

    @Test(.failureMode("design/29", "a challenge is forged, altered, or from another server"),
          .failureMode("design/29", "an enrolment challenge is used for requests, or the reverse"))
    func aChallengeThisServerDidNotIssueForThisPurposeIsRefused() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        var altered = challenge.bytes
        altered[12] ^= 0x01
        let otherServer = try AppAttestChallenges(keys: [Secret(Array(repeating: UInt8(8), count: 32))])
        let foreign = await rig.run { otherServer.issue(.requests) }
        let enrolmentChallenge = await rig.run { rig.gate.challenge(.enrolment) }
        for nonce in [altered, foreign.bytes, enrolmentChallenge.bytes] {
            #expect(await rig.verify(try Signing().signed(by: keyID, on: rig.device, nonce: nonce)).refusal == "stale_challenge")
        }
        // The reverse: a request challenge offered for enrolment.
        let key = rig.device.generateKey()
        let wrong = AppAttestEnrolment(key: key, attestation: try rig.device.attest(key, clientDataHash: sha256(challenge.bytes)), challenge: challenge.bytes)
        #expect(await rig.enrol(wrong).refusal == "challenge_invalid")
    }

    @Test(.failureMode("design/29", "the client's clock is wrong"))
    func theClientsClockIsNeverRead() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        var signing = Signing()
        signing.extraHeaders = [("Date", "Fri, 31 Dec 1999 23:59:59 GMT")]
        _ = try await rig.verify(try signing.signed(by: keyID, on: rig.device, nonce: challenge.bytes)).get()
    }

    // MARK: Requests

    @Test(.failureMode("design/29", "a genuine app signs a check-in with a faked location"))
    func aSignedRequestVerifiesAndProvesOriginNotTruth() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        let signing = Signing()  // latitude 51.5, longitude -0.12: wherever the phone said
        guard case .attested(let attested, let fresh) = try await rig.verify(try signing.signed(by: keyID, on: rig.device, nonce: challenge.bytes)).get() else {
            Issue.record("not attested")
            return
        }
        #expect(fresh == nil, "the challenge is not yet half way through its life")
        #expect(attested.value.authority == serverAuthority && attested.value.path == "/v1/check-ins" && attested.value.query == "event=e42")
        #expect(attested.value.body == signing.body && attested.value.idempotencyKey == signing.idempotencyKey)
        #expect(attested.evidence.counter == 1 && attested.evidence.account == "volunteer-7" && attested.evidence.app == kindora)
        #expect(!AppAttested.proves.contains("true"), "it proves origin and integrity, never that the location is true")
        struct CheckIn: Decodable { let commitment: String; let latitude: Double }
        let body = try attested.deriving { try JSONDecoder().decode(CheckIn.self, from: Data($0.body)) }
        #expect(body.value.latitude == 51.5 && body.evidence == attested.evidence)
        #expect(await rig.ledger.records.first?.counter.highest == 1)
    }

    @Test func aFreshChallengeIsSentOnceTheOldOneIsHalfWayThrough() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        await rig.clock.advance(by: .seconds(160))
        guard case .attested(_, let fresh) = try await rig.verify(try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes)).get() else {
            Issue.record("not attested")
            return
        }
        let header = try #require(fresh.map(AppAttestGate.challengeHeader))
        #expect(header.name == "App-Attest-Challenge" && header.value.hasSuffix(":;lifetime=300"))
    }

    @Test(.failureMode("design/29", "an assertion is replayed"),
          .failureMode("design/29", "a captured request is replayed from another device"))
    func aReplayedRequestIsRefusedAndChangesNothing() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        let request = try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes)
        _ = try await rig.verify(request).get()
        let record = await rig.ledger.records.first
        let replay = await rig.verify(request)
        #expect(replay.refusal == "replayed")
        #expect(await rig.ledger.records.first == record, "the record is unchanged")
        // Once its challenge expires, the captured request is stale as well.
        await rig.clock.advance(by: .seconds(301))
        #expect(await rig.verify(request).refusal == "stale_challenge")
    }

    @Test(.failureMode("design/29", "a counter regresses below the window"))
    func aCounterBelowTheWindowIsReplayedReportedAndNeverRevokes() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        var high = Signing()
        high.counter = 100
        _ = try await rig.verify(try high.signed(by: keyID, on: rig.device, nonce: challenge.bytes)).get()
        var low = Signing()
        low.counter = 50
        #expect(await rig.verify(try low.signed(by: keyID, on: rig.device, nonce: challenge.bytes)).refusal == "replayed")
        let event = try #require(rig.events.events(named: "attest.counter_regression").first)
        #expect(event.level == .warning && event["distance"]?.description == "50")
        #expect(!event.description.contains(keyID))
        #expect(await rig.ledger.records.first?.status == .active, "never revoked automatically")
    }

    @Test(.failureMode("design/29", "assertions arrive out of order within the window"))
    func outOfOrderCountersAreEachAcceptedOnce() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        var requests: [SignedRequest] = []
        for counter in UInt32(1)...8 {
            var signing = Signing()
            signing.counter = counter
            signing.idempotencyKey = "k\(counter)"
            requests.append(try signing.signed(by: keyID, on: rig.device, nonce: challenge.bytes))
        }
        for index in [7, 2, 5, 0, 1, 6, 3, 4] { _ = try await rig.verify(requests[index]).get() }
        for request in requests { #expect(await rig.verify(request).refusal == "replayed") }
    }

    @Test(.failureMode("design/29", "two servers accept the same counter at once"))
    func twoServersOneCounterOneWins() async throws {
        let shared = InMemoryAppAttestLedger()
        let pausing = PausingLedger(shared)
        let rig = try AttestationRig(ledger: shared, gateLedger: pausing)
        let (keyID, challenge) = try await rig.enrolledKey()
        let request = try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes)
        pausing.holdCommits(2)
        async let first = rig.verify(request)
        async let second = rig.verify(request)
        await pausing.waitForHeldCommits(2)
        pausing.releaseCommits()
        let outcomes = [await first, await second]
        #expect(outcomes.filter { (try? $0.get()) != nil }.count == 1, "one commit wins")
        #expect(outcomes.compactMap(\.refusal) == ["replayed"], "the other reloads, finds the bit set")
        #expect(rig.events.events(named: "attest.commit_conflict").count == 1)
    }

    @Test(.failureMode("design/29", "commits keep conflicting"))
    func persistentConflictsAreUnavailableNotARefusal() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        await rig.ledger.conflictNextCommits(15)
        _ = try await rig.verify(try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes)).get()
        await rig.ledger.conflictNextCommits(16)
        var next = Signing()
        next.idempotencyKey = "k2"
        guard case .failure(let refusal) = await rig.verify(try next.signed(by: keyID, on: rig.device, nonce: challenge.bytes)) else {
            Issue.record("committed through sixteen conflicts")
            return
        }
        #expect(refusal.code == "unavailable" && refusal.status == 503 && refusal.retryDecision == .retry)
        #expect(rig.events.events(named: "attest.commit_conflict").last?.level == .warning)
    }

    @Test(.failureMode("design/29", "a server instance's clock is ahead"))
    func aChallengeFromAClockAheadIsAcceptedWithinTheSkew() async throws {
        let rig = try AttestationRig()
        let (keyID, _) = try await rig.enrolledKey()
        let ahead = try AppAttestChallenges(keys: [challengeKey])
        let soon = ahead.issue(.requests, at: TestClock.wallClockStart + .seconds(25))
        let later = ahead.issue(.requests, at: TestClock.wallClockStart + .seconds(35))
        _ = try await rig.verify(try Signing().signed(by: keyID, on: rig.device, nonce: soon.bytes)).get()
        #expect(await rig.verify(try Signing().signed(by: keyID, on: rig.device, nonce: later.bytes)).refusal == "stale_challenge")
        #expect(rig.events.events(named: "attest.assertion_refused").last?["check"]?.description == "challenge_fromTheFuture")
    }

    @Test(.failureMode("design/29", "the body is altered"))
    func anAlteredBodyIsADigestMismatch() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        let signed = try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes)
        let altered = SignedRequest(method: signed.method, path: signed.path, query: signed.query,
                                    headers: headers(of: signed), body: Array(#"{"commitment":"c8"}"#.utf8))
        #expect(await rig.verify(altered).refusal == "invalid")
        #expect(rig.events.events(named: "attest.assertion_refused").last?["check"]?.description == "body_digest")
    }

    @Test(.failureMode("design/29", "the path, query, method or a covered header is altered"),
          .failureMode("design/29", "a proxy rewrites the path or the query"))
    func anyCoveredComponentAlteredBreaksTheSignature() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        let signed = try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes)
        var others = headers(of: signed)
        others.removeAll { $0.name.lowercased() == "idempotency-key" }
        let variants = [
            SignedRequest(method: "PUT", path: signed.path, query: signed.query, headers: headers(of: signed), body: signed.body),
            SignedRequest(method: signed.method, path: "/v1/check-ins/", query: signed.query, headers: headers(of: signed), body: signed.body),
            SignedRequest(method: signed.method, path: signed.path, query: "event=e43", headers: headers(of: signed), body: signed.body),
            SignedRequest(method: signed.method, path: signed.path, query: signed.query, headers: others + [("Idempotency-Key", "other")], body: signed.body),
        ]
        for variant in variants {
            #expect(await rig.verify(variant).refusal == "invalid")
            #expect(rig.events.events(named: "attest.assertion_refused").last?["check"]?.description == "signature")
        }
    }

    @Test(.failureMode("design/29", "a proxy rewrites Host"))
    func theConfiguredAuthorityIsSignedNotTheHostReceived() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        // Support's requests arrive with `Host: internal-lb.local`.
        _ = try await rig.verify(try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes)).get()
        var other = Signing()
        other.authority = "internal-lb.local"
        #expect(await rig.verify(try other.signed(by: keyID, on: rig.device, nonce: challenge.bytes)).refusal == "invalid",
                "a client that signed another authority is refused")
    }

    @Test(.failureMode("design/29", "the signature covers fewer components than v1 requires"))
    func fewerComponentsThanV1IsRefused() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        let signing = Signing()
        let input = #"attest=("@method" "@authority" "@path" "@query");keyid="\#(keyID)";nonce="\#(Base64.encode(challenge.bytes))";alg="apple-app-attest""#
        let request = signing.request(signatureInput: input, signature: "attest=:AA==:")
        #expect(await rig.verify(request).refusal == "invalid")
        #expect(rig.events.events(named: "attest.assertion_refused").last?["check"]?.description == "components")
    }

    @Test(.failureMode("design/29", "a key enrolled for one account signs for another"))
    func aKeyIsBoundToItsAccountAndAnAnonymousOneToNone() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey(account: "volunteer-7")
        let request = try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes)
        guard case .failure(let refusal) = await rig.verify(request, account: "volunteer-8") else { Issue.record("another account"); return }
        #expect(refusal.code == "account_mismatch" && refusal.cause == "account" && refusal.status == 401)
        _ = try await rig.verify(request, account: "volunteer-7").get()
        let (anonymous, second) = try await rig.enrolledKey(account: nil)
        _ = try await rig.verify(try Signing().signed(by: anonymous, on: rig.device, nonce: second.bytes), account: "anyone").get()
    }

    @Test(.failureMode("design/29", "a key's counter reaches UInt32.max"))
    func anExhaustedCounterRemovesTheKeySoTheClientEnrolsAnother() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        var last = Signing()
        last.counter = UInt32.max
        _ = try await rig.verify(try last.signed(by: keyID, on: rig.device, nonce: challenge.bytes)).get()
        var after = Signing()
        after.counter = 1
        after.idempotencyKey = "after"
        #expect(await rig.verify(try after.signed(by: keyID, on: rig.device, nonce: challenge.bytes)).refusal == "unknown_key")
        #expect(await rig.ledger.records.isEmpty)
    }

    @Test(.failureMode("design/29", "a modified app claims to be unsupported"))
    func aClaimOfUnsupportedIsAClaimTheServiceDecidesOn() async throws {
        let declared = Signing().request(signatureInput: nil, signature: nil)
        let claiming = SignedRequest(method: "POST", path: "/v1/check-ins", query: "", headers: headers(of: declared) + [("App-Attest", "unsupported;reason=mac")], body: declared.body)
        let accepting = try AttestationRig(ifUnsupported: .accept)
        guard case .unsupported(let claim) = try await accepting.verify(claiming).get() else { Issue.record("not a claim"); return }
        #expect(claim == Claimed(.mac))
        #expect(accepting.events.events(named: "attest.unsupported_client").first?["accepted"]?.description == "true")
        let refusing = try AttestationRig(ifUnsupported: .refuse)
        #expect(await refusing.verify(claiming).refusal == "unsupported_refused")
        #expect(await refusing.verify(declared).refusal == "missing", "neither a signature nor a claim")
    }

    @Test func aLedgerThatFailsIsUnavailableNeverARefusal() async throws {
        struct Broken: AppAttestLedger {
            struct Down: Error {}
            func key(_ id: [UInt8]) async throws -> AppAttestKeyRecord? { throw Down() }
            func insert(_ record: AppAttestKeyRecord) async throws -> Bool { throw Down() }
            func commit(_ record: AppAttestKeyRecord, over revision: UInt64) async throws -> Bool { throw Down() }
            func remove(_ id: [UInt8]) async throws { throw Down() }
            func spend(challenge id: [UInt8], until expiry: Moment) async throws -> Bool { throw Down() }
        }
        let rig = try AttestationRig(gateLedger: Broken())
        let (_, enrolment) = try await rig.attestedKey()
        guard case .failure(let refusal) = await rig.enrol(enrolment) else { Issue.record("enrolled with no ledger"); return }
        #expect(refusal.code == "unavailable" && refusal.status == 503 && refusal.retryDecision == .retry)
        let event = try #require(rig.events.events(named: "attest.ledger_failed").first)
        #expect(event.level == .error && event["error"]?.description.hasSuffix("Down") == true)
    }

    @Test func anUnknownOrRevokedKeyIsRefusedByItsOwnCode() async throws {
        let rig = try AttestationRig()
        let (keyID, challenge) = try await rig.enrolledKey()
        let request = try Signing().signed(by: keyID, on: rig.device, nonce: challenge.bytes)
        let record = try #require(await rig.ledger.records.first)
        _ = await rig.ledger.commit(record.revoked(because: "fraud", at: TestClock.wallClockStart), over: record.revision)
        #expect(await rig.verify(request).refusal == "revoked")
        await rig.ledger.remove(record.key.id)
        #expect(await rig.verify(request).refusal == "unknown_key")
    }
}

extension Result where Failure == AppAttestRefusal {
    var refusal: String? { if case .failure(let refusal) = self { refusal.code } else { nil } }
    var cause: String? { if case .failure(let refusal) = self { refusal.cause } else { nil } }
    var status: Int? { if case .failure(let refusal) = self { refusal.status } else { nil } }
}

extension AppAttestEnrolment {
    init(key: String, attestation: [UInt8], challenge: [UInt8]) {
        self.init(keyID: key, attestation: attestation, challenge: challenge)
    }
}

/// The headers of a request, as given to `SignedRequest`.
func headers(of request: SignedRequest) -> [(name: String, value: String)] {
    ["content-digest", "host", "idempotency-key", "signature-input", "signature", "app-attest"].flatMap { name in
        request.values(name).map { (name: name, value: $0) }
    }
}

/// A ledger whose commits wait until the test lets them through: two
/// servers verifying the same request at once.
final class PausingLedger: AppAttestLedger {
    private let inner: InMemoryAppAttestLedger
    private let state = Mutex<(holding: Int, held: [CheckedContinuation<Void, Never>])>((0, []))

    init(_ inner: InMemoryAppAttestLedger) { self.inner = inner }

    func holdCommits(_ count: Int) { state.withLock { $0.holding = count } }

    func waitForHeldCommits(_ count: Int) async {
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: .seconds(10))
        while state.withLock({ $0.held.count }) < count, clock.now < limit { try? await clock.sleep(for: .milliseconds(1)) }
    }

    func releaseCommits() {
        let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            defer { state.held = [] }
            return state.held
        }
        for waiter in held { waiter.resume() }
    }

    func key(_ id: [UInt8]) async throws -> AppAttestKeyRecord? { await inner.key(id) }
    func insert(_ record: AppAttestKeyRecord) async throws -> Bool { await inner.insert(record) }
    func remove(_ id: [UInt8]) async throws { await inner.remove(id) }
    func spend(challenge id: [UInt8], until expiry: Moment) async throws -> Bool { await inner.spend(challenge: id, until: expiry) }

    func commit(_ record: AppAttestKeyRecord, over revision: UInt64) async throws -> Bool {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                guard state.holding > 0 else { return true }
                state.holding -= 1
                state.held.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
        return await inner.commit(record, over: revision)
    }
}
#endif
