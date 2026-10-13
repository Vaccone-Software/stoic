// expect-error: retry needs a bounded schedule
//
// `retry` takes only a `BoundedSchedule`. A schedule that never ends
// (`.fixed(...)` on its own) is for polling, not retrying; the compiler
// refuses it until `.attempts(_:)` or `.delays(_:)` bounds it (design/02).
import Stoic

func retryForever() async throws {
    try await retry(.fixed(.seconds(1))) { _ in }
}
