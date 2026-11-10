// The control for the attestation fixtures: StoicAttestation's public API,
// used as intended, compiles with the Attestation trait.
import Stoic
import StoicAttestation

func serve(_ gate: AppAttestGate, _ request: SignedRequest, _ enrolment: AppAttestEnrolment) async throws {
    _ = gate.challenge(.enrolment)
    _ = try await gate.enrol(enrolment, account: "volunteer-7")
    do throws(AppAttestRefusal) {
        switch try await gate.verify(request, account: "volunteer-7") {
        case .attested(let attested, let fresh):
            let body: Verified<Int, AppAttested> = attested.deriving { $0.body.count }
            _ = (body.evidence.counter, body.evidence.app, fresh.map(AppAttestGate.challengeHeader))
        case .unsupported(let claim):
            _ = claim
        }
    } catch {
        _ = (gate.headers(for: error), error.status, error.code)
    }
}

func make() throws -> AppAttestGate {
    AppAttestGate(
        app: try AppID("A1B2C3D4E5.app.kindora"), environment: .production, authority: "api.kindora.app",
        challenges: try AppAttestChallenges(keys: [Secret(Array(repeating: 1, count: 32))]),
        ledger: InMemoryAppAttestLedger(), ifUnsupported: .accept)
}
