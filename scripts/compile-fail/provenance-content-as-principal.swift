// expect-error: requires that 'Attested' conform to 'PrincipalEvidence'
//
// Content evidence (who sent these bytes) is not principal evidence (who is
// asking): an attested request cannot stand in for an authenticated person
// where a lifecycle records who acted (design/28).
import Stoic

struct Attested: ContentEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "a genuine app sent these bytes"
}
private let attester = Minter<Attested>(Attested.Mint())

func record<E: PrincipalEvidence>(by principal: Verified<String, E>) {}

record(by: attester.verified("volunteer-7", Attested()))
