// expect-error: requires that 'Opaque' conform to 'Equatable'
//
// An Action's input says what a person asked for: a trigger joins or
// continues an intent only with an equal input, so the input is Equatable or
// Void (design/31).
import Stoic
import StoicLive

struct Opaque: Sendable {}

@MainActor
func make() -> Action<Opaque, Int> {
    Action(Backend.remote("api").idempotent("save")) { (_: Opaque, _: Attempt) async throws -> Int in 1 }
}
