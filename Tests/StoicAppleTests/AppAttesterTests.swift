#if canImport(DeviceCheck) && canImport(CryptoKit)
import CryptoKit
import DeviceCheck
import Foundation
import Stoic
@testable import StoicApple
import StoicTesting
import Testing

@Suite("App Attest: the attester")
struct AppAttesterTests {
    typealias Outcome = Result<AppAttestKeyID, AppAttestError>

    // MARK: Unsupported

    @Test(.failureMode("design/29", "the device cannot attest (a Mac, the simulator, an extension, older hardware)"))
    func availabilityIsDecidedOnceFromThePlatformAndTheService() async {
        func decide(_ supported: Bool, simulator: Bool = false, mac: Bool = false, appex: Bool = false, watch: Bool = false) -> AppAttestAvailability {
            AppAttester.availability(
                isSupported: supported, platform: AppAttestPlatform(isSimulator: simulator, isMac: mac, isAppExtension: appex, isWatch: watch))
        }
        #expect(decide(true, simulator: true) == .unsupported(.simulator))
        #expect(decide(false, mac: true) == .unsupported(.mac))
        #expect(decide(true, mac: true) == .supported, "a Mac that says it can is tried")
        #expect(decide(true, appex: true) == .unsupported(.appExtension), "whatever isSupported says")
        #expect(decide(true, appex: true, watch: true) == .supported, "watchOS extensions support it")
        #expect(decide(false) == .unsupported(.device))
        #expect(decide(true) == .supported)

        let rig = AttesterRig()
        let mac = await rig.attester(platform: AppAttestPlatform(isSimulator: false, isMac: true, isAppExtension: false, isWatch: false))
        #expect(mac.availability == .supported)
        let unsupported = ScriptedAppAttestService(isSupported: false)
        let attester = await rig.run {
            AppAttester(account: "a", secrets: rig.store, server: rig.server, service: unsupported, policy: .standard, platform: aPhone)
        }
        #expect(attester.availability == .unsupported(.device))
        #expect(await rig.outcome(attester) == .failure(.unsupported(.device)))
        #expect(await rig.outcome(attester) == .failure(.unsupported(.device)))
        #expect(await attester.state == .unsupported(.device))
        #expect(unsupported.calls.isEmpty, "nothing generated, attested or stored")
        #expect(rig.store.inner.keys.isEmpty && rig.server.issued.isEmpty)
        #expect(rig.events.events(named: "attest.unsupported").count == 1, "once per attester")
        #expect(rig.events.events(named: "attest.unsupported").first?["reason"]?.description == "device")
    }

    @Test(.failureMode("design/29", "isSupported is true and generateKey says featureUnsupported"))
    func featureUnsupportedFromTheServiceIsTheSame() async {
        let rig = AttesterRig()
        rig.service.fail(.generateKey, with: .featureUnsupported)
        let attester = await rig.attester()
        #expect(await rig.outcome(attester) == .failure(.unsupported(.device)))
        #expect(await attester.state == .unsupported(.device))
        #expect(await rig.outcome(attester) == .failure(.unsupported(.device)), "never retried")
        #expect(rig.service.calls(.generateKey).count == 1)
        #expect(rig.events.events(named: "attest.unsupported").count == 1)
    }

    // MARK: Enrolment

    @Test(.failureMode("design/29", "the key's record is absent (a new install, a restore to another device)"))
    func anEnrolmentWritesEachPhaseAndEndsEnrolled() async throws {
        let rig = AttesterRig()
        let attester = await rig.attester()
        let key = try await rig.outcome(attester).get()
        #expect(key.base64 == "key-1")
        #expect(key.description == "key-1…")
        #expect(rig.store.phase(of: "volunteer-7") == "enrolled")
        #expect(rig.server.issued == [.enrolment])
        let attest = try #require(rig.service.calls(.attestKey).first)
        #expect(attest.clientDataHash == Array(SHA256.hash(data: [1, 1])), "SHA-256 of the challenge's bytes")
        let enrolment = try #require(rig.server.enrolments.first)
        #expect(enrolment.attestation == Array("attestation:key-1:\(hex(attest.clientDataHash ?? []))".utf8))
        #expect(await attester.state == .enrolled(key))
        let event = try #require(rig.events.events(named: "attest.enrolled").first)
        #expect(event["keys"]?.description == "1" && event["replaced"]?.description == "false")
        #expect(!event.description.contains("key-1"), "a key id is never recorded")
        // Once enrolled, nothing more is asked of anyone, in this process or the next.
        #expect(try await rig.outcome(attester).get() == key)
        let next = await rig.attester()
        #expect(try await rig.outcome(next).get() == key)
        #expect(rig.service.calls(.generateKey).count == 1 && rig.service.calls(.attestKey).count == 1)
        #expect(rig.server.enrolments.count == 1)
        #expect(try await rig.outcome(attester).get() == key)
    }

    @Test(.failureMode("design/29", "the account changes"))
    func anotherAccountHasAnotherRecordAndAnotherKey() async throws {
        let rig = AttesterRig()
        let first = try await rig.outcome(await rig.attester(account: "volunteer-7")).get()
        let second = try await rig.outcome(await rig.attester(account: "parent-3")).get()
        #expect(first != second)
        #expect(rig.store.inner.keys == ["stoic.app-attest.parent-3", "stoic.app-attest.volunteer-7"])
    }

    @Test(.failureMode("design/29", "many requests arrive while an enrolment is in flight"))
    func aHundredCallersShareOneEnrolment() async throws {
        let rig = AttesterRig()
        rig.service.delay(.attestKey, by: .seconds(1))
        let attester = await rig.attester()
        let callers = (0..<100).map { _ in Task { await rig.outcome(attester) } }
        await rig.clock.waitForSleepers(count: 2)
        await eventually { await attester.enrolmentWaiters == 100 }
        await rig.clock.advance(by: .seconds(1))
        var keys: Set<AppAttestKeyID> = []
        for caller in callers { keys.insert(try await caller.value.get()) }
        #expect(keys.count == 1)
        #expect(rig.service.calls(.generateKey).count == 1)
        #expect(rig.service.calls(.attestKey).count == 1)
        #expect(rig.server.enrolments.count == 1)
    }

    @Test(.failureMode("design/29", "a waiting request's deadline is shorter than the enrolment"))
    func aWaiterLeavesAtItsDeadlineAndTheEnrolmentGoesOn() async throws {
        let rig = AttesterRig()
        rig.service.delay(.attestKey, by: .seconds(30))
        let attester = await rig.attester()
        let hurried = Task {
            await rig.run {
                await withDeadline(Deadline.after(.seconds(5))) { () async -> Outcome in await rig.outcome(attester) }
            }
        }
        await rig.clock.waitForSleepers(count: 3)
        await rig.clock.advance(by: .seconds(5))
        #expect(await hurried.value == .failure(.timedOut))
        #expect(await attester.state == .enrolling, "the enrolment goes on")
        await rig.clock.advance(by: .seconds(25))
        await eventually { await attester.state == .enrolled(AppAttestKeyID(base64: "key-1")) }
        #expect(try await rig.outcome(attester).get().base64 == "key-1")
    }

    @Test(.failureMode("design/29", "the request that started the enrolment is cancelled"))
    func theStartersCancellationEndsOnlyItsOwnWait() async throws {
        let rig = AttesterRig()
        rig.service.delay(.attestKey, by: .seconds(10))
        let attester = await rig.attester()
        let starter = Task { await rig.outcome(attester) }
        await rig.clock.waitForSleepers(count: 2)
        let other = Task { await rig.outcome(attester) }
        await eventually { await attester.enrolmentWaiters == 2 }
        starter.cancel()
        #expect(await starter.value == .failure(.cancelled))
        #expect(AppAttestError.cancelled.isCancellation)
        await rig.clock.advance(by: .seconds(10))
        #expect(try await other.value.get().base64 == "key-1")
    }

    @Test(.failureMode("design/29", "Apple's service is unavailable during enrolment"))
    func anUnavailableServiceIsAskedAgainWithTheSameKeyAndHashThenResumed() async throws {
        let rig = AttesterRig()
        rig.service.fail(.attestKey, with: .serverUnavailable, times: 50)
        let attester = await rig.attester()
        let first = Task { await rig.outcome(attester) }
        #expect(await rig.drive(first) == .failure(.serviceUnavailable))
        let attempts = rig.service.calls(.attestKey)
        #expect(attempts.count == 5, "at 0, 2, 6, 14 and 30 s: the next wait (32 s) would outlast the minute")
        #expect(Set(attempts.map(\.keyID)) == ["key-1"] && Set(attempts.map(\.clientDataHash)).count == 1, "the same key and hash")
        #expect(rig.events.events(named: "attest.service_unavailable").map { $0["retry_in"]?.description } == ["2.0 seconds", "4.0 seconds", "8.0 seconds", "16.0 seconds"])
        #expect(AppAttestError.serviceUnavailable.retryDecision == .retry)
        #expect(rig.store.phase(of: "volunteer-7") == "attesting")
        // Apple is back: the next call resumes with the same key.
        rig.service.reset(.attestKey)
        #expect(try await rig.outcome(attester).get().base64 == "key-1")
        #expect(rig.service.calls(.generateKey).count == 1)
    }

    @Test(.failureMode("design/29", "the enrolment challenge's lifetime passes while Apple is unavailable"))
    func aStaleChallengeIsReplacedAndTheKeyKept() async throws {
        let rig = AttesterRig()
        rig.server.setEnrolmentLifetime(.seconds(5))
        rig.service.fail(.attestKey, with: .serverUnavailable, times: 3)
        let attester = await rig.attester()
        let task = Task { await rig.outcome(attester) }
        #expect(try await rig.drive(task).get().base64 == "key-1")
        let hashes = rig.service.calls(.attestKey).map(\.clientDataHash)
        #expect(hashes.count == 4)
        #expect(hashes[0] == hashes[1], "0 s and 2 s: one challenge")
        #expect(hashes[1] != hashes[2], "at 6 s the 5 s challenge is stale: a new one")
        #expect(rig.server.issued == [.enrolment, .enrolment, .enrolment])
        #expect(Set(rig.service.calls(.attestKey).map(\.keyID)) == ["key-1"])
    }

    @Test(.failureMode("design/29", "the process dies after generateKey, before the key id is kept"))
    func aKeyWhoseIdWasNeverKeptIsOrphanedAndAnotherGenerated() async throws {
        let rig = AttesterRig()
        rig.store.failWrite(1)
        let dying = await rig.attester()
        #expect(await rig.outcome(dying) == .failure(.keychain(.unavailable)))
        #expect(rig.store.phase(of: "volunteer-7") == nil)
        let next = await rig.attester()
        #expect(try await rig.outcome(next).get().base64 == "key-2", "key-1 is orphaned in the Secure Enclave")
    }

    @Test(.failureMode("design/29", "the process dies after attestKey, before the attestation is kept"))
    func anAttestationThatWasNeverKeptCostsOneExtraKey() async throws {
        let rig = AttesterRig()
        rig.store.failWrite(3)
        let dying = await rig.attester()
        #expect(await rig.outcome(dying) == .failure(.keychain(.unavailable)))
        #expect(rig.store.phase(of: "volunteer-7") == "attesting")
        let next = await rig.attester()
        #expect(try await rig.outcome(next).get().base64 == "key-2")
        #expect(rig.service.calls(.attestKey).map(\.keyID) == ["key-1", "key-1", "key-2"], "key-1 was already attested: invalidKey")
        #expect(rig.server.enrolments.map(\.key) == ["key-2"])
    }

    @Test(.failureMode("design/29", "the enrolment's response is lost"))
    func aLostResponseResendsTheKeptAttestation() async throws {
        let rig = AttesterRig()
        rig.server.failEnrol(with: .unreachable(.retry, neverReachedBackend: false))
        let attester = await rig.attester()
        #expect(await rig.outcome(attester) == .failure(.serverUnavailable(.retry)))
        #expect(rig.store.phase(of: "volunteer-7") == "attested")
        #expect(try await rig.outcome(attester).get().base64 == "key-1")
        let enrolments = rig.server.enrolments
        #expect(enrolments.count == 2 && enrolments[0] == enrolments[1], "the same key, attestation and challenge")
        #expect(rig.service.calls(.attestKey).count == 1, "Apple was asked once")
    }

    @Test(.failureMode("design/29", "the server refuses the attestation"))
    func aRefusedEnrolmentHoldsOffForAnHour() async throws {
        let rig = AttesterRig()
        rig.server.failEnrol(with: .refused(code: "invalid_attestation"))
        let attester = await rig.attester()
        #expect(await rig.outcome(attester) == .failure(.enrolmentRefused(code: "invalid_attestation")))
        #expect(AppAttestError.enrolmentRefused(code: "x").retryDecision == .stop)
        #expect(await attester.state == .failed(.enrolmentRefused(code: "invalid_attestation")))
        #expect(rig.store.phase(of: "volunteer-7") == "refused", "the key is discarded; the refusal is kept")
        #expect(await rig.outcome(attester) == .failure(.enrolmentRefused(code: "invalid_attestation")))
        // The next launch remembers the refusal too.
        #expect(await rig.outcome(await rig.attester()) == .failure(.enrolmentRefused(code: "invalid_attestation")))
        #expect(rig.service.calls(.generateKey).count == 1, "no key is spent during the hold-off")
        let failed = try #require(rig.events.events(named: "attest.enrolment_failed").first)
        #expect(failed.level == .warning && failed["code"]?.description == "enrolment_refused")
        await rig.clock.advance(by: .seconds(3600))
        #expect(try await rig.outcome(attester).get().base64 == "key-2")
    }

    @Test(.failureMode("design/29", "the enrolment challenge expired between attestKey and the POST"))
    func aSpentChallengeSpendsTheKeyAndEnrolsAnother() async throws {
        let rig = AttesterRig()
        rig.server.failEnrol(with: .refused(code: "challenge_expired"))
        let attester = await rig.attester()
        let key = try await rig.outcome(attester).get()
        #expect(key.base64 == "key-2")
        #expect(rig.server.enrolments.map(\.key) == ["key-1", "key-2"])
        #expect(rig.events.events(named: "attest.enrolled").first?["replaced"]?.description == "false")
        #expect(rig.events.events(named: "attest.enrolled").first?["keys"]?.description == "2")
    }

    @Test(.failureMode("design/29", "a fresh key is refused too"))
    func aSecondSpentKeyIsARefusal() async throws {
        let rig = AttesterRig()
        rig.service.fail(.attestKey, with: .invalidKey, times: 2)
        let attester = await rig.attester()
        #expect(await rig.outcome(attester) == .failure(.keyRefused))
        #expect(rig.service.calls(.generateKey).count == 2, "a fresh key after a spent one, never a third")
        #expect(rig.events.events(named: "attest.key_refused").first?.level == .error)
        #expect(await rig.outcome(attester) == .failure(.keyRefused))
        #expect(rig.service.calls(.generateKey).count == 2)
        #expect(AppAttestError.keyRefused.retryDecision == .stop)
    }

    @Test(.failureMode("design/29", "DCError.invalidInput is thrown"))
    func invalidInputIsADefect() async {
        let rig = AttesterRig()
        rig.service.fail(.attestKey, with: .invalidInput)
        let attester = await rig.attester()
        #expect(await rig.outcome(attester) == .failure(.invalidInput))
        let event = rig.events.events(named: "attest.invalid_input").first
        #expect(event?.level == .error && event?["operation"]?.description == "attestKey")
        #expect(AppAttestError.invalidInput.retryDecision == .stop)
    }

    @Test(.failureMode("design/29", "DCError.unknownSystemFailure is thrown"))
    func aSystemFailureIsRetriedThreeTimes() async throws {
        let rig = AttesterRig()
        rig.service.fail(.generateKey, with: .unknownSystemFailure, times: 3)
        let attester = await rig.attester()
        #expect(await rig.outcome(attester) == .failure(.systemFailure))
        #expect(rig.service.calls(.generateKey).count == 3)
        #expect(AppAttestError.systemFailure.retryDecision == .retry)
        rig.service.fail(.generateKey, with: .unknownSystemFailure, times: 2)
        #expect(try await rig.outcome(attester).get().base64 == "key-1", "two failures, then a key")
        // Another domain: Foundation's table decides.
        rig.service.fail(.generateAssertion, withError: URLError(.timedOut), times: 1)
        let key = try await rig.outcome(attester).get()
        let signed = await rig.run { () async -> Result<[UInt8], AppAttestError> in
            do throws(AppAttestError) { return .success(try await attester.assertion(over: Array(repeating: 1, count: 32), with: key)) } catch { return .failure(error) }
        }
        #expect((try? signed.get()) != nil, "a transient URLError is retried as a system failure")
    }

    @Test(.failureMode("design/29", "the Keychain is locked when the key's record is read"))
    func aLockedKeychainIsNoReasonToGenerateAKey() async {
        let rig = AttesterRig()
        rig.store.failNext(with: .locked)
        let attester = await rig.attester()
        #expect(await rig.outcome(attester) == .failure(.keychain(.locked)))
        #expect(AppAttestError.keychain(.locked).retryDecision == .retry)
        #expect(rig.service.calls.isEmpty, "no key is generated")
    }

    // MARK: Assertions and dead keys

    @Test(.failureMode("design/29", "the device's key is invalidated (reinstall, restore, migration)"))
    func aDeadKeyIsDiscardedAndAnotherEnrolled() async throws {
        let rig = AttesterRig()
        let attester = await rig.attester()
        let key = try await rig.outcome(attester).get()
        rig.service.invalidate(key.base64)
        let hash = Array(repeating: UInt8(7), count: 32)
        let result = await rig.run { () async -> Result<[UInt8], AppAttestError> in
            do throws(AppAttestError) { return .success(try await attester.assertion(over: hash, with: key)) } catch { return .failure(error) }
        }
        #expect(result == .failure(.keyInvalidated))
        #expect(rig.events.events(named: "attest.key_invalidated").count == 1)
        #expect(rig.store.phase(of: "volunteer-7") == nil)
        #expect(try await rig.outcome(attester).get().base64 == "key-2")
        #expect(rig.events.events(named: "attest.enrolled").last?["replaced"]?.description == "true", "it replaced the dead key")
    }

    @Test(.failureMode("design/29", "two requests find the same dead key"))
    func twoRequestsOnOneDeadKeyEnrolOnce() async throws {
        let rig = AttesterRig()
        let attester = await rig.attester()
        let key = try await rig.outcome(attester).get()
        rig.service.invalidate(key.base64)
        let hash = Array(repeating: UInt8(7), count: 32)
        let signers = (0..<2).map { _ in
            Task {
                await rig.run { () async -> AppAttestError? in
                    do throws(AppAttestError) {
                        _ = try await attester.assertion(over: hash, with: key)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
        }
        for signer in signers { #expect(await signer.value == .keyInvalidated) }
        let reenrolled = (0..<2).map { _ in Task { await rig.outcome(attester) } }
        for task in reenrolled { #expect(try await task.value.get().base64 == "key-2") }
        #expect(rig.service.calls(.generateKey).count == 2, "one re-enrolment")
        #expect(rig.events.events(named: "attest.key_invalidated").count == 1)
    }

    @Test func anAssertionSignsTheHashWithTheEnrolledKey() async throws {
        let rig = AttesterRig()
        let attester = await rig.attester()
        let key = try await rig.outcome(attester).get()
        let hash = Array(repeating: UInt8(9), count: 32)
        let assertion = try await rig.run { () async throws -> [UInt8] in try await attester.assertion(over: hash, with: key) }
        #expect(String(decoding: assertion, as: UTF8.self) == "assertion:1:key-1:\(hex(hash))")
        let stale = await rig.run { () async -> AppAttestError? in
            do throws(AppAttestError) {
                _ = try await attester.assertion(over: hash, with: AppAttestKeyID(base64: "key-0"))
                return nil
            } catch {
                return error
            }
        }
        #expect(stale == .keyInvalidated, "a key that is not the enrolled one never reaches the device")
        #expect(rig.service.calls(.generateAssertion).count == 1)
    }

    @Test func aRevokedKeyHoldsOffEnrolment() async throws {
        let rig = AttesterRig()
        let attester = await rig.attester()
        let key = try await rig.outcome(attester).get()
        try await attester.revoked(key)
        #expect(await rig.outcome(attester) == .failure(.enrolmentRefused(code: "revoked")))
        #expect(rig.service.calls(.generateKey).count == 1)
        await rig.clock.advance(by: .seconds(3600))
        #expect(try await rig.outcome(attester).get().base64 == "key-2")
    }

    @Test func theFirstRequestChallengeIsHandedOverOnce() async throws {
        let rig = AttesterRig()
        let attester = await rig.attester()
        _ = try await rig.outcome(attester).get()
        let first = try await rig.run { () async throws -> AppAttestChallenge in try await attester.requestChallenge() }
        #expect(first.bytes == [2, 0], "the one the enrolment returned")
        let second = try await rig.run { () async throws -> AppAttestChallenge in try await attester.requestChallenge() }
        #expect(second.bytes == [2, 2], "then the server's")
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
}

func eventually(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let limit = clock.now.advanced(by: .seconds(10))
    while !(await condition()) {
        if clock.now >= limit {
            Issue.record("the condition never became true", sourceLocation: sourceLocation)
            return
        }
        try? await clock.sleep(for: .milliseconds(1))
    }
}
#endif
