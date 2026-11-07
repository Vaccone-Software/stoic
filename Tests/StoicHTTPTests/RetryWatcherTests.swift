import Foundation
import Stoic
@testable import StoicHTTP
import StoicTesting
import Testing

/// The watcher the client puts in front of a retry's events to learn why the
/// retry stopped: `retry` rethrows the last error whatever the reason, so the
/// events are the only place that says a budget was spent or a wait would have
/// outlasted the deadline.
@Suite("Retry watcher")
struct RetryWatcherTests {
    static let label = "http api.example.com"

    static func watcher() -> (RetryWatcher, RecordingInstrumentation) {
        let inner = RecordingInstrumentation()
        return (RetryWatcher(forwardingTo: inner, label: label), inner)
    }

    static func budgetExhausted(label: String? = label) -> Event {
        Event("retry.budget_exhausted", level: .warning, label: label)
    }

    static func deadlineSkip(_ delay: Duration?, label: String? = label) -> Event {
        Event("retry.deadline_skip", level: .notice, label: label, fields: delay.map { [.init("delay", .duration($0))] } ?? [])
    }

    @Test func aRetryThatHasNotStoppedHasNoReason() {
        let (watcher, _) = Self.watcher()
        #expect(watcher.stopReason == nil)
    }

    @Test func aSpentBudgetIsRemembered() {
        let (watcher, _) = Self.watcher()
        watcher.record(Self.budgetExhausted())
        #expect(watcher.stopReason == .budgetExhausted)
    }

    @Test func aWaitThatWouldOutlastTheDeadlineIsRememberedWithItsLength() {
        let (watcher, _) = Self.watcher()
        watcher.record(Self.deadlineSkip(.seconds(2)))
        #expect(watcher.stopReason == .deadlineSkip(wait: .seconds(2)))
    }

    @Test func aLaterSkipReplacesAnEarlierOne() {
        let (watcher, _) = Self.watcher()
        watcher.record(Self.deadlineSkip(.seconds(2)))
        watcher.record(Self.deadlineSkip(.seconds(5)))
        #expect(watcher.stopReason == .deadlineSkip(wait: .seconds(5)))
    }

    @Test func aSkipThatNamesNoWaitIsNotAReason() {
        let (watcher, _) = Self.watcher()
        watcher.record(Self.deadlineSkip(.seconds(2)))
        watcher.record(Self.deadlineSkip(nil))
        #expect(watcher.stopReason == .deadlineSkip(wait: .seconds(2)), "the earlier skip stands")
    }

    @Test(arguments: [true, false])
    func aSpentBudgetIsTheReasonWhicheverArrivesFirst(budgetFirst: Bool) {
        let (watcher, _) = Self.watcher()
        let events = [Self.budgetExhausted(), Self.deadlineSkip(.seconds(2))]
        for event in budgetFirst ? events : events.reversed() { watcher.record(event) }
        // The client reports a retry that gave both reasons as a spent budget.
        #expect(watcher.stopReason == .budgetExhausted)
    }

    @Test func eventsOfAnotherLabelAreNotThisRetrysReason() {
        let (watcher, _) = Self.watcher()
        watcher.record(Self.budgetExhausted(label: "http other.example.com"))
        watcher.record(Self.deadlineSkip(.seconds(2), label: nil))
        #expect(watcher.stopReason == nil)
    }

    @Test func everyEventIsForwardedUnchanged() {
        let (watcher, inner) = Self.watcher()
        let sent = [
            Self.deadlineSkip(.seconds(2)),
            Event("retry.attempt_failed", level: .info, label: Self.label),
            Self.budgetExhausted(label: "http other.example.com"),
            Self.budgetExhausted(),
            Self.deadlineSkip(nil, label: nil),
        ]
        for event in sent { watcher.record(event) }
        #expect(inner.names == sent.map(\.name))
        #expect(inner.events.map(\.label) == sent.map(\.label))
        #expect(inner.events.map(\.level) == sent.map(\.level))
        #expect(inner.events.map(\.fields.count) == sent.map(\.fields.count))
    }
}
