#if canImport(AppKit)
import AppKit
import Stoic
import StoicAppKit
import StoicTesting
import Testing

@Suite("GracefulTermination")
@MainActor
struct GracefulTerminationTests {
    @Test func repliesWhenShutdownFinishes() async {
        let replies = SendableReplies()
        let done = TestGate()
        let termination = GracefulTermination(deadline: .seconds(10), clock: TestClock().erased) {
            done.open()
        }
        #expect(termination.shouldTerminate { replies.append($0) } == .terminateLater)
        await done.wait()
        for _ in 0..<200 where replies.values.isEmpty { await Task.yield() }
        #expect(replies.values == [true])
        #expect(termination.shouldTerminate { replies.append($0) } == .terminateNow)
    }

    @Test func aSecondRequestWhileTerminatingWaits() {
        let termination = GracefulTermination(deadline: .seconds(10), clock: TestClock().erased) {
            await TestGate().wait()
        }
        #expect(termination.shouldTerminate { _ in } == .terminateLater)
        #expect(termination.shouldTerminate { _ in } == .terminateLater)
    }

    @Test func aHungShutdownStillQuitsAtTheDeadline() async {
        let clock = TestClock()
        let replies = SendableReplies()
        let events = RecordingInstrumentation()
        let termination = withEvents(events) {
            GracefulTermination(deadline: .seconds(8), clock: clock.erased) { await TestGate().wait() }
        }
        _ = await withAmbient({ $0.instrumentation = events }) {
            termination.shouldTerminate { replies.append($0) }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(8))
        for _ in 0..<500 where replies.values.isEmpty { await Task.yield() }
        #expect(replies.values == [true])
        #expect(events.names.contains("lifecycle.terminate_overran"))
    }

    private func withEvents<T>(_ events: RecordingInstrumentation, _ body: () -> T) -> T { body() }
}

@MainActor
final class SendableReplies {
    var values: [Bool] = []
    func append(_ value: Bool) { values.append(value) }
}
#endif
