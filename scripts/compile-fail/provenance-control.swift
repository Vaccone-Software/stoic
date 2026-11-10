// The provenance control: every public API of design/28 used as intended
// compiles. If this fails, the provenance-* files fail for the wrong reason.
import Stoic

struct Session: PrincipalEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "the request carried a live session token for this person"
    let sessionID: String
}
private let sessions = Minter<Session>(Session.Mint())

struct Signed: ContentEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "a sender signed these bytes"
}
private let signer = Minter<Signed>(Signed.Mint())

func verify(_ token: Claimed<String>) -> Verified<String, Session> {
    sessions.verified("volunteer-" + sessions.read(token), Session(sessionID: "s1"))
}

enum Edit: Permission {
    typealias Subject = Int
    typealias Principal = String
    static let name = "events.edit"
}

struct Owner: PermissionPolicy {
    typealias Granting = Edit                   // a policy names the permission it decides
    let name = "owner"
    func decide(_ principal: Verified<String, Session>, _ subject: Int) async throws -> PermissionDecision {
        principal.value == "volunteer-7" ? .allow : .deny("someone else's")
    }
}

func accept(at moment: Verified<Moment, OwnClock>, by person: Verified<String, Session>) -> Moment { moment.value }

func edit(_ grant: Granted<Edit>) -> (Int, String, String, Moment) {
    (grant.value, grant.evidence.principal, grant.evidence.policy, grant.evidence.decidedAt)
}

func handle() async throws {
    let me = verify(Claimed("7"))
    _ = accept(at: Moment.stamped(), by: me)
    let check = try await Owner().check(Claimed(42), by: me)
    switch check {
    case .granted(let grant): _ = edit(grant)
    case .denied(let denial): _ = (denial.reason, denial.policy, denial.subject, denial.principal)
    case .unknown(.loading), .unknown(.unavailable): break
    }
    do throws(PermissionRefusal<Edit>) {
        _ = edit(try check.granted())
    } catch {
        switch error {
        case .denied: _ = error.retryDecision
        case .unknown: _ = error.retryDecision
        }
    }
    let bytes = signer.verified([UInt8]([1, 2, 3]), Signed())
    let count: Verified<Int, Signed> = bytes.deriving { $0.count }
    let claim: Claimed<Int> = count.claim
    let doubled: Claimed<Int> = claim.map { $0 * 2 }
    _ = (Signed.proves, Session.proves, OwnClock.proves, Grant<Edit>.proves, doubled, PermissionDecision.unknown(.loading))
}
