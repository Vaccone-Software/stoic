// expect-error: 'nil' is not compatible with expected argument type 'any Actor'
//
// A TaskSlot's check that nothing newer has started and its delivery are
// atomic only because one actor runs both, with any `run` that could come
// between. Called from nonisolated code there is no such actor, so the
// compiler refuses the call (design/03).
import Stoic

final class Owner {}

func runOffAnActor(_ slot: TaskSlot<Int, Never>, owner: Owner) {
    slot.run(for: owner) { 1 } deliver: { _, _ in }
}
