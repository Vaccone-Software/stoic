// expect-error: binary operator '==' cannot be applied to two 'PermissionCheck<Edit>' operands
//
// Nor can it be compared with `.granted` as a test of "allowed": the grant is
// the value, and a view switches on the outcome (design/28).
import Stoic

enum Edit: Permission {
    typealias Subject = Int
    typealias Principal = String
    static let name = "edit"
}

func draw(_ check: PermissionCheck<Edit>) -> Bool {
    check == .granted
}
