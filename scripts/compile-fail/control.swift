// The control: correct use compiles. If this fails, the harness is broken
// (a missing module, a changed flag) and the "expect-error" files below
// would pass for the wrong reason.
import Stoic

func useScopeInsideItsBody() async {
    await withScope { (scope: borrowing Scope) async in
        scope.onExit { _ in }
    }
}
