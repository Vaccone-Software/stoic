@testable import Stoic
@testable import StoicTesting
import Synchronization
import Testing

/// A task that sleeps twice, in order, on a clock: a retrying loop's shape.
func sleepTwice(on clock: TestClock, _ first: Duration, then second: Duration) -> Task<Void, any Error> {
    Task {
        try await clock.sleep(until: clock.now.advanced(by: first))
        try await clock.sleep(until: clock.now.advanced(by: second))
    }
}

/// `waitForSleepers` must never hang silently: a wait that cannot be met
/// ends with an issue that prints the clock's state (design/12).
@Suite("waitForSleepers")
struct TestClockWaitTests {
    static func recordedIssues(_ body: () async throws -> Void) async rethrows -> [String] {
        let messages = Mutex<[String]>([])
        try await withKnownIssue(isIntermittent: true) {
            try await body()
        } matching: { issue in
            messages.withLock { $0.append(issue.comments.map(\.rawValue).joined(separator: "\n")) }
            return true
        }
        return messages.withLock { $0 }
    }

    @Test func aSatisfiedWaitRecordsNothing() async throws {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(10)) }
        await clock.waitForSleepers(count: 1, timeout: .seconds(30))
        sleeper.cancel()
    }

    @Test(.timeLimit(.minutes(1))) func aSleeperThatNeverComesTimesOutWithTheClocksState() async throws {
        let clock = TestClock()
        let sleeper = Task { try await clock.sleep(for: .seconds(10)) }
        await clock.waitForSleepers(count: 1)
        let started = ContinuousClock.now
        let issues = await Self.recordedIssues {
            await clock.waitForSleepers(count: 3, timeout: .milliseconds(100))
        }
        #expect(started.duration(to: .now) < .seconds(10), "the timeout is in real time")
        #expect(issues.count == 1)
        let message = issues.first ?? ""
        #expect(message.contains("waitForSleepers(count: 3)"))
        #expect(message.contains("gave up after"))
        #expect(message.contains("at least 3 asleep at once"))
        #expect(message.contains("TestClock now +0"))
        #expect(message.contains("1 asleep"))
        #expect(message.contains("wakes at +10.0 seconds"))
        #expect(message.contains("totalSleeps"))   // names the way out
        sleeper.cancel()
    }

    @Test func aCancelledWaitIsReportedNotTreatedAsSatisfied() async throws {
        let clock = TestClock()
        let issues = await Self.recordedIssues {
            let waiter = Task { await clock.waitForSleepers(count: 1, timeout: nil) }
            try? await Task.sleep(for: .milliseconds(10))
            waiter.cancel()
            await waiter.value
        }
        #expect(issues.count == 1)
        #expect(issues.first?.contains("was cancelled while waiting") == true)
        #expect(issues.first?.contains("0 asleep") == true)
    }

    @Test func aTimeoutOfNilWaitsUntilTheSleeperArrives() async throws {
        let clock = TestClock()
        let waiter = Task { await clock.waitForSleepers(count: 1, timeout: nil) }
        try? await Task.sleep(for: .milliseconds(20))
        let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
        await waiter.value
        sleeper.cancel()
    }

    // MARK: "At least, now" and the way to wait for a new sleep

    @Test func theCountIsAtLeastNowSoItCanBeSatisfiedByTheWrongSleeper() async throws {
        let clock = TestClock()
        let looping = sleepTwice(on: clock, .seconds(1), then: .seconds(100))
        let bystander = Task { try await clock.sleep(for: .seconds(1000)) }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .seconds(1))   // wakes `looping`; it will sleep again
        // Already true because of the bystander, whether or not `looping`
        // has gone back to sleep: documented, and the reason for newerThan.
        await clock.waitForSleepers(count: 1, timeout: .seconds(1))
        looping.cancel()
        bystander.cancel()
    }

    @Test(.timeLimit(.minutes(1))) func waitingForNewerSleepersIsExactAfterAnAdvance() async throws {
        let clock = TestClock()
        let looping = sleepTwice(on: clock, .seconds(1), then: .seconds(100))
        let bystander = Task { try await clock.sleep(for: .seconds(1000)) }
        await clock.waitForSleepers(count: 2)
        let mark = clock.totalSleeps
        await clock.advance(by: .seconds(1))
        await clock.waitForSleepers(newerThan: mark)
        // The second sleep has begun: the loop's next deadline is registered.
        #expect(clock.pendingDeadlines.contains(TestClock.Instant(offset: .seconds(101))))
        #expect(clock.totalSleeps == mark + 1)
        looping.cancel()
        bystander.cancel()
    }

    @Test func waitingForMoreNewSleepsThanWillComeIsReported() async throws {
        let clock = TestClock()
        let mark = clock.totalSleeps
        let sleeper = Task { try await clock.sleep(for: .seconds(1)) }
        let issues = await Self.recordedIssues {
            await clock.waitForSleepers(newerThan: mark, count: 2, timeout: .milliseconds(100))
        }
        #expect(issues.count == 1)
        #expect(issues.first?.contains("waitForSleepers(newerThan: \(mark), count: 2)") == true)
        #expect(issues.first?.contains("1 asleep") == true)
        sleeper.cancel()
    }

    @Test func theSummaryListsSleepersEarliestFirst() async throws {
        let clock = TestClock()
        let late = Task { try await clock.sleep(for: .seconds(30)) }
        let early = Task { try await clock.sleep(for: .seconds(5)) }
        await clock.waitForSleepers(count: 2)
        let summary = clock.summary
        let earlier = summary.firstRange(of: "+5.0 seconds")
        let later = summary.firstRange(of: "+30.0 seconds")
        #expect(earlier != nil && later != nil && earlier!.lowerBound < later!.lowerBound, "\(summary)")
        late.cancel()
        early.cancel()
    }
}
