// expect-error: requires that 'AppAttested' conform to 'PrincipalEvidence'
//
// App Attest proves which app and device key sent the bytes, never who the
// user is: an attested request does not pass where a person must be
// authenticated (design/29, design/28).
import Stoic
import StoicAttestation

func checkIn<E: PrincipalEvidence>(by person: Verified<AttestedRequest, E>) {}

func handle(_ outcome: GateOutcome) {
    if case .attested(let request, _) = outcome { checkIn(by: request) }
}
