// expect-error: is consuming
//
// Storing the handle past the body would need a copy; a borrowed,
// noncopyable value cannot be consumed.
import Stoic

func keep() async {
    var kept: Scope? = nil
    await withScope { (scope: borrowing Scope) async in
        kept = scope
    }
    _ = kept
}
