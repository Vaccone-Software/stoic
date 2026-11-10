// expect-error: requires that 'Session' conform to 'ContentEvidence'
//
// Relabelling a volunteer as staff is not authentication: `deriving` does
// not exist for principal evidence (design/28).
import Stoic

struct Session: PrincipalEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "a live session"
}
private let sessions = Minter<Session>(Session.Mint())

let staff = sessions.verified("volunteer-7", Session()).deriving { $0 + " (staff)" }
