// expect-error: cannot convert value of type 'String' to expected argument type 'Granted<EditEvent>'
//
// A delete takes the proof, and the proof cannot exist while the
// permissions load: an event id is not one (design/31, design/28).
import Stoic
import StoicLive

enum EditEvent: Permission {
    typealias Subject = String
    typealias Principal = String
    static let name = "edit-event"
}

@MainActor
func tapDelete(_ delete: Action<Granted<EditEvent>, Void>, event: String) {
    delete.trigger(event)
}
