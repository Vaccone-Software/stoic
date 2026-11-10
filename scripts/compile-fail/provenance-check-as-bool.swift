// expect-error: cannot convert value of type 'PermissionCheck<Edit>' to expected condition type 'Bool'
//
// A permission check has three outcomes and no `Bool`: "unknown" cannot be
// read as "denied" or "allowed" (design/28).
import Stoic

enum Edit: Permission {
    typealias Subject = Int
    typealias Principal = String
    static let name = "edit"
}

func draw(_ check: PermissionCheck<Edit>) {
    if check {}
}
