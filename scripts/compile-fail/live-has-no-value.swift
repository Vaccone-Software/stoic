// expect-error: 'value' is inaccessible due to 'private' protection level
//
// There is no value to read while a Live loads (what it holds is private):
// a screen switches on its phase (design/31).
import Stoic
import StoicLive

@MainActor
func count(_ roster: Live<[String]>) -> Int {
    roster.value.count
}
