// The control for the Live and Action fixtures: the same module, used as
// design/31 intends, compiles.
import Stoic
import StoicLive

enum EditEvent: Permission {
    typealias Subject = String
    typealias Principal = String
    static let name = "edit-event"
}

@MainActor
func draw(_ roster: Live<[String]>, _ canEdit: Live<PermissionCheck<EditEvent>>, _ delete: Action<Granted<EditEvent>, Void>) -> String {
    switch canEdit.check() {
    case .granted(let proof): delete.trigger(proof)
    case .denied, .unknown: break
    }
    switch roster.phase {
    case .pending: return "waiting"
    case .fresh(let names), .stale(let names, refreshing: _), .failed(_, last: let names?): return names.joined()
    case .failed(_, last: nil): return "failed"
    }
}
