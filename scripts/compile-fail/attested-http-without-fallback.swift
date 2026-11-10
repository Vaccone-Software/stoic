// expect-error: missing argument for parameter 'ifUnsupported' in call
//
// What an app that cannot attest does is the app's decision: the
// authenticator has no default for it (design/29, rule 2).
import StoicApple
import StoicAttestedHTTP

func make(_ attester: AppAttester) -> AppAttestAuthenticator {
    AppAttestAuthenticator(attester)
}
