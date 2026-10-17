// Deliberately no `import Testing`: this file is what an XCTest suite looks
// like, and it must compile by importing StoicTesting alone (design/12).
import Stoic
import StoicTesting
import Synchronization
import XCTest

final class TestClockXCTestTests: XCTestCase {
    func testWaitingForSleepersNeedsNoTestingImport() async {
        let clock = TestClock()
        let woke = Flag()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(30))
            woke.set()
        }
        await clock.waitForSleepers(count: 1)
        XCTAssertFalse(woke.isSet)
        let mark = clock.totalSleeps
        await clock.advance(by: .seconds(30))
        _ = try? await sleeper.value
        XCTAssertTrue(woke.isSet)

        let again = Task { try await clock.sleep(for: .seconds(5)) }
        await clock.waitForSleepers(newerThan: mark, count: 1, timeout: .seconds(5))
        await clock.advance(by: .seconds(5))
        _ = try? await again.value
        XCTAssertEqual(clock.totalSleeps, mark + 1)
    }
}

private final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
