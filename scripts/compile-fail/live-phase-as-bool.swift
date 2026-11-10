// expect-error: to expected condition type 'Bool'
//
// A Live's phase is four cases, never a Bool: "loading" cannot read as
// "empty" or "not permitted" (design/31).
import Stoic
import StoicLive

@MainActor
func draw(_ roster: Live<[String]>) -> String {
    if roster.phase { return "ready" }
    return "waiting"
}
