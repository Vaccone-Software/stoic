// expect-error: type 'ByDevice' does not conform to protocol 'PermissionPolicy'
//
// Nor can a permission policy take an attested request as its principal:
// a policy's principals carry principal evidence (design/29).
import Stoic
import StoicAttestation

enum CheckIn: Permission {
    typealias Subject = String
    typealias Principal = AttestedRequest
    static let name = "attendance.check-in"
}

struct ByDevice: PermissionPolicy {
    typealias Granting = CheckIn
    typealias Authentication = AppAttested
    let name = "by-device"
    func decide(_ principal: Verified<AttestedRequest, AppAttested>, _ subject: String) async throws -> PermissionDecision { .allow }
}
