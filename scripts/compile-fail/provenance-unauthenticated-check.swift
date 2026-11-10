// expect-error: cannot convert value of type 'String' to expected argument type 'Verified<
//
// A check takes a verified principal: "who is asking" as a plain argument
// does not compile (design/28).
import Stoic

struct Session: PrincipalEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "a live session"
}

enum Edit: Permission {
    typealias Subject = Int
    typealias Principal = String
    static let name = "edit"
}

struct Owner: PermissionPolicy {
    typealias Granting = Edit
    let name = "owner"
    func decide(_ principal: Verified<String, Session>, _ subject: Int) async throws -> PermissionDecision { .allow }
}

func handle() async throws {
    _ = try await Owner().check(Claimed(42), by: "volunteer-7")
}
