// expect-error: cannot be captured by an escaping closure
import Stoic

func escape() async throws {
    try await withTaskScope { (scope: borrowing TaskScope) async throws in
        Task {
            scope.fork(label: "after the scope ended") {}
        }
    }
}
