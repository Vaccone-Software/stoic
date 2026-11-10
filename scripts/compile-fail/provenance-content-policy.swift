// expect-error: type 'ByDevice' does not conform to protocol 'PermissionPolicy'
//
// A policy's principals carry principal evidence: one that would decide on
// content evidence does not conform (design/28).
import Stoic

struct Attested: ContentEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "a genuine app sent these bytes"
}

enum Edit: Permission {
    typealias Subject = Int
    typealias Principal = String
    static let name = "edit"
}

struct ByDevice: PermissionPolicy {
    typealias Granting = Edit
    typealias Authentication = Attested
    let name = "by-device"
    func decide(_ principal: Verified<String, Attested>, _ subject: Int) async throws -> PermissionDecision { .allow }
}
