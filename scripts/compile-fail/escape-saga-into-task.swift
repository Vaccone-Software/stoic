// expect-error: cannot be captured by an escaping closure
import Stoic

func escape() async {
    await withSaga { (saga: borrowing Saga) async in
        Task { _ = saga }
    }
}
