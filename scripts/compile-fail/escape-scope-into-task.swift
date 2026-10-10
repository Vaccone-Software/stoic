// expect-error: cannot be captured by an escaping closure
//
// design/04: "The handle cannot escape". A Task outlives the body, so a
// finalizer could be registered on a scope that has already ended.
import Stoic

func escape() async {
    await withScope { (scope: borrowing Scope) async in
        Task {
            scope.onExit { _ in }
        }
    }
}
