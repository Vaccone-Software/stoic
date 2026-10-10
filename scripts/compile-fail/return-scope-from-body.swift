// expect-error: requires that 'Scope' conform to 'Copyable'
//
// withScope returns the body's result by value, so a body cannot hand the
// handle back to its caller.
import Stoic

func leak() async {
    let _: Scope = await withScope { (scope: borrowing Scope) async -> Scope in
        return scope
    }
}
