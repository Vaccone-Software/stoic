// expect-error: to expected condition type 'Bool'
//
// A live permission check has three outcomes; loading is `.unknown`, which
// nothing turns into a Bool (design/31, design/28).
import Stoic
import StoicLive

enum EditEvent: Permission {
    typealias Subject = String
    typealias Principal = String
    static let name = "edit-event"
}

@MainActor
func showsEdit(_ canEdit: Live<PermissionCheck<EditEvent>>) -> Bool {
    if canEdit.check() { return true }
    return false
}
