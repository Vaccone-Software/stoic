@testable import Stoic
import StoicTesting
import Testing

@Suite("Debouncer and Throttler")
struct DebounceThrottleTests {
    enum Boom: Error, Equatable { case boom }

    func ms(_ clock: TestClock) -> Int { Int(clock.now.offset / .milliseconds(1)) }

    /// A call that waits for its fate: its operation returns `name@time`, and
    /// the task's value is that, or the reason the call was rejected.
    func call<P: Policy>(_ policy: P, _ name: String, _ clock: TestClock, log: SendableBox<[String]>) -> Task<String, Never> {
        Task {
            let result = await outcome(of: policy) { () async -> String in
                let ran = "\(name)@\(ms(clock))"
                log.mutate { $0.append(ran) }
                return ran
            }
            switch result {
            case .success(let ran): return ran
            case .failure(let error): return error.rejection?.reason.rawValue ?? "failed"
            }
        }
    }

    /// Lets work that is ready to run run.
    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Debouncer

    @Test(.stoic(seed: 31), .timeLimit(.minutes(1)), .failureMode("design/20", "a debounced call arrives while an earlier one waits"))
    func aNewerCallSupersedesTheWaitingOne() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let debouncer = Debouncer(quiet: .milliseconds(300), label: "search", clock: clock.erased)
        let a = call(debouncer, "A", clock, log: log)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(100))
        let mark = clock.totalSleeps
        let b = call(debouncer, "B", clock, log: log)
        await clock.waitForSleepers(newerThan: mark)
        #expect(await a.value == "superseded")
        await clock.advance(by: .milliseconds(299))   // 399: A's period is over, B's is not
        await settle()
        #expect(log.value.isEmpty)
        await clock.advance(by: .milliseconds(1))
        #expect(await b.value == "B@400")
        let drops = StoicTest.events.events(named: "debounce.dropped")
        #expect(drops.map(\.label) == ["search"])
        #expect(drops.first?.text("reason") == "superseded")
    }

    @Test(.stoic(seed: 32), .timeLimit(.minutes(1)), .failureMode("design/20", "the quiet period passes with no newer call"))
    func theLatestCallRunsOnceTheQuietPeriodPasses() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let debouncer = Debouncer(quiet: .milliseconds(300), label: "quiet", clock: clock.erased)
        let a = call(debouncer, "A", clock, log: log)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(299))
        await settle()
        #expect(log.value.isEmpty)
        await clock.advance(by: .milliseconds(1))
        #expect(await a.value == "A@300")
        #expect(log.value == ["A@300"])
        #expect(clock.sleeperCount == 0)
    }

    @Test(.stoic(seed: 33), .timeLimit(.minutes(1)), .failureMode("design/20", "`leading` is on and a call opens a burst"))
    func aLeadingCallRunsAtOnceAndATrailingOneEndsTheBurst() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let debouncer = Debouncer(quiet: .milliseconds(300), leading: true, trailing: true, label: "both", clock: clock.erased)
        #expect(await call(debouncer, "A", clock, log: log).value == "A@0")
        await clock.advance(by: .milliseconds(100))
        let mark = clock.totalSleeps
        let b = call(debouncer, "B", clock, log: log)
        await clock.waitForSleepers(newerThan: mark)
        await clock.advance(by: .milliseconds(300))
        #expect(await b.value == "B@400")
        // A burst of one call runs once, not again at its end.
        #expect(await call(debouncer, "C", clock, log: log).value == "C@400")
        await clock.advance(by: .seconds(5))
        await settle()
        #expect(log.value == ["A@0", "B@400", "C@400"])
    }

    @Test(.stoic(seed: 34), .timeLimit(.minutes(1)), .failureMode("design/20", "`leading` only and a call arrives inside the burst"))
    func aLeadingOnlyDebouncerSuppressesAndExtendsTheBurst() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let debouncer = Debouncer(quiet: .milliseconds(300), leading: true, trailing: false, label: "leading", clock: clock.erased)
        #expect(await call(debouncer, "A", clock, log: log).value == "A@0")
        await clock.advance(by: .milliseconds(100))
        #expect(await call(debouncer, "B", clock, log: log).value == "suppressed")
        await clock.advance(by: .milliseconds(250))   // 350: past A's burst, inside B's extension
        #expect(await call(debouncer, "C", clock, log: log).value == "suppressed")
        await clock.advance(by: .milliseconds(350))   // 700: the burst is over
        #expect(await call(debouncer, "D", clock, log: log).value == "D@700")
        let drops = StoicTest.events.events(named: "debounce.dropped")
        #expect(drops.compactMap { $0.text("reason") } == ["suppressed", "suppressed"])
    }

    @Test(.stoic(seed: 35), .timeLimit(.minutes(1)), .failureMode("design/20", "a waiting debounced call is cancelled"))
    func aCancelledWaitingCallIsWithdrawn() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let debouncer = Debouncer(quiet: .milliseconds(300), label: "cancel", clock: clock.erased)
        let a = call(debouncer, "A", clock, log: log)
        await clock.waitForSleepers(count: 1)
        a.cancel()
        #expect(await a.value == "cancelled")
        await clock.advance(by: .seconds(1))
        await settle()
        #expect(log.value.isEmpty)
        #expect(clock.sleeperCount == 0)
        // A deadline that cancels the wait is a deadline, not an abandonment.
        let b = Task { () -> Rejection.Reason? in
            do throws(PolicyError<Never>) {
                _ = try await withTimeout(.milliseconds(100), clock: clock.erased) { () async throws(PolicyError<Never>) -> Int in
                    try await debouncer.execute { () async -> Int in 1 }
                }
                return nil
            } catch {
                return error.rejection?.reason
            }
        }
        await clock.waitForSleepers(count: 2)
        await clock.advance(by: .milliseconds(100))
        #expect(await b.value == .deadlineExceeded)
    }

    @Test(.stoic(seed: 36), .timeLimit(.minutes(1)), .failureMode("design/20", "the scope that owns a `submit` ends"))
    func endingTheScopeWithdrawsASubmittedCall() async throws {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let debouncer = Debouncer(quiet: .milliseconds(300), label: "submit", clock: clock.erased)
        try await withTaskScope { scope in
            debouncer.submit(in: scope) { log.mutate { $0.append("ran") } }
            await clock.waitForSleepers(count: 1)
        }
        await clock.advance(by: .seconds(1))
        await settle()
        #expect(log.value.isEmpty)
        #expect(clock.sleeperCount == 0)
        // Inside a scope that lives long enough, the call runs.
        try await withTaskScope { scope in
            debouncer.submit(in: scope) { log.mutate { $0.append("ran") } }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .milliseconds(300))
            await waitUntil { log.value == ["ran"] }
        }
    }

    @Test(.stoic(seed: 37), .timeLimit(.minutes(1)), .failureMode("design/20", "a debounced operation throws"))
    func anOperationsErrorIsTheCallersAndTheNextCallStartsAfresh() async {
        let clock = TestClock()
        let debouncer = Debouncer(quiet: .milliseconds(100), label: "throws", clock: clock.erased)
        let failing = Task {
            await outcome(of: debouncer) { () async throws(Boom) -> Int in throw Boom.boom }
        }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(100))
        #expect(await failing.value.error?.failure == .boom)
        let next = Task { await outcome(of: debouncer) { () async -> Int in 7 } }
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(100))
        #expect((try? await next.value.get()) == 7)
    }

    // MARK: - Throttler

    @Test(.stoic(seed: 41), .timeLimit(.minutes(1)), .failureMode("design/20", "a call arrives inside the window with `trailing` off"))
    func aLeadingThrottlerSuppressesCallsInsideTheWindow() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let throttler = Throttler(interval: .seconds(1), label: "autosave", clock: clock.erased)
        #expect(await call(throttler, "A", clock, log: log).value == "A@0")
        await clock.advance(by: .milliseconds(500))
        #expect(await call(throttler, "B", clock, log: log).value == "suppressed")
        await clock.advance(by: .milliseconds(500))
        #expect(await call(throttler, "C", clock, log: log).value == "C@1000")
        let drops = StoicTest.events.events(named: "throttle.dropped")
        #expect(drops.map(\.label) == ["autosave"])
        #expect(drops.first?.text("reason") == "suppressed")
    }

    @Test(.stoic(seed: 42), .timeLimit(.minutes(1)), .failureMode("design/20", "calls arrive inside the window with `trailing` on"))
    func aTrailingThrottlerKeepsOnlyTheLatestCallOfTheWindow() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let throttler = Throttler(interval: .seconds(1), leading: true, trailing: true, label: "latest", clock: clock.erased)
        #expect(await call(throttler, "A", clock, log: log).value == "A@0")
        await clock.advance(by: .milliseconds(200))
        let b = call(throttler, "B", clock, log: log)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(200))
        let mark = clock.totalSleeps
        let c = call(throttler, "C", clock, log: log)
        await clock.waitForSleepers(newerThan: mark)
        #expect(await b.value == "superseded")
        await clock.advance(by: .milliseconds(599))
        await settle()
        #expect(log.value == ["A@0"])
        await clock.advance(by: .milliseconds(1))
        #expect(await c.value == "C@1000")
        #expect(StoicTest.events.events(named: "throttle.dropped").compactMap { $0.text("reason") } == ["superseded"])
    }

    @Test(.stoic(seed: 43), .timeLimit(.minutes(1)), .failureMode("design/20", "a trailing call runs"))
    func aTrailingRunOpensTheNextWindow() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let throttler = Throttler(interval: .seconds(1), leading: true, trailing: true, label: "windows", clock: clock.erased)
        _ = await call(throttler, "A", clock, log: log).value
        await clock.advance(by: .milliseconds(200))
        let b = call(throttler, "B", clock, log: log)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(800))
        #expect(await b.value == "B@1000")
        // B opened a window to 2000: a call at 1100 waits for it, not for 2100.
        await clock.advance(by: .milliseconds(100))
        let mark = clock.totalSleeps
        let c = call(throttler, "C", clock, log: log)
        await clock.waitForSleepers(newerThan: mark)
        await clock.advance(by: .milliseconds(900))
        #expect(await c.value == "C@2000")
        #expect(log.value == ["A@0", "B@1000", "C@2000"])
    }

    @Test(.stoic(seed: 44), .timeLimit(.minutes(1)), .failureMode("design/20", "`leading` is off and a call opens a window"))
    func aTrailingOnlyThrottlerWaitsForTheWindowToEnd() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let throttler = Throttler(interval: .seconds(1), leading: false, trailing: true, label: "late", clock: clock.erased)
        let a = call(throttler, "A", clock, log: log)
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .milliseconds(999))
        await settle()
        #expect(log.value.isEmpty)
        await clock.advance(by: .milliseconds(1))
        #expect(await a.value == "A@1000")
    }

    @Test(.stoic(seed: 45), .timeLimit(.minutes(1)), .failureMode("design/20", "a call waiting for the window's end is cancelled"))
    func aCancelledTrailingCallLeavesTheWindowOpen() async {
        let clock = TestClock()
        let log = SendableBox<[String]>([])
        let throttler = Throttler(interval: .seconds(1), leading: false, trailing: true, label: "window", clock: clock.erased)
        let a = call(throttler, "A", clock, log: log)
        await clock.waitForSleepers(count: 1)
        a.cancel()
        #expect(await a.value == "cancelled")
        await clock.advance(by: .milliseconds(300))
        let mark = clock.totalSleeps
        let b = call(throttler, "B", clock, log: log)
        await clock.waitForSleepers(newerThan: mark)
        await clock.advance(by: .milliseconds(700))
        #expect(await b.value == "B@1000")   // the window A opened, not 1300
    }

    // MARK: - Late timers

    /// A clock whose time is set by hand and whose timers fire only when
    /// `inner` is advanced: a timer that fires late, as every real one does.
    struct LateClock: Clock {
        typealias Instant = TestClock.Instant
        let inner: TestClock
        let offset: SendableBox<Duration>
        var now: Instant { Instant(offset: offset.value) }
        var minimumResolution: Duration { .zero }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try await inner.sleep(until: deadline, tolerance: tolerance)
        }
    }

    /// A call whose operation returns `name@time`, on a late clock.
    func call<P: Policy>(_ policy: P, _ name: String, at offset: SendableBox<Duration>) -> Task<String, Never> {
        Task {
            let result = await outcome(of: policy) { () async -> String in "\(name)@\(Int(offset.value / .milliseconds(1)))" }
            switch result {
            case .success(let ran): return ran
            case .failure(let error): return error.rejection?.reason.rawValue ?? "failed"
            }
        }
    }

    @Test(.stoic(seed: 46), .timeLimit(.minutes(1)), .failureMode("design/20", "a call arrives after the quiet period, before its timer fires"))
    func aDueDebouncedCallRunsThoughItsTimerIsLate() async {
        let inner = TestClock()
        let offset = SendableBox<Duration>(.zero)
        let debouncer = Debouncer(quiet: .milliseconds(300), label: "late", clock: AnyClock(LateClock(inner: inner, offset: offset)))
        let a = call(debouncer, "A", at: offset)
        await inner.waitForSleepers(count: 1)
        offset.mutate { $0 = .milliseconds(301) }   // A's burst is over; its timer has not fired
        let b = call(debouncer, "B", at: offset)
        #expect(await a.value == "A@301", "previously superseded by a call after its burst")
        await inner.waitForSleepers(count: 1)        // B's; A's timer ended with A
        offset.mutate { $0 = .milliseconds(601) }
        await inner.advance(to: .init(offset: .milliseconds(601)))
        #expect(await b.value == "B@601")            // B opened a burst of its own
    }

    @Test(.stoic(seed: 47), .timeLimit(.minutes(1)), .failureMode("design/20", "a call arrives after the window ends, before its timer fires"))
    func aDueTrailingCallRunsThoughItsTimerIsLate() async {
        let inner = TestClock()
        let offset = SendableBox<Duration>(.zero)
        let throttler = Throttler(interval: .seconds(1), leading: false, trailing: true, label: "late",
                                  clock: AnyClock(LateClock(inner: inner, offset: offset)))
        let a = call(throttler, "A", at: offset)
        await inner.waitForSleepers(count: 1)
        offset.mutate { $0 = .milliseconds(1001) }  // A's window is over; its timer has not fired
        let b = call(throttler, "B", at: offset)
        #expect(await a.value == "A@1001", "previously superseded, and B ran at once")
        await inner.waitForSleepers(count: 1)
        offset.mutate { $0 = .milliseconds(2001) }
        await inner.advance(to: .init(offset: .milliseconds(2001)))
        #expect(await b.value == "B@2001")           // A's run opened the next window: runs stay `interval` apart
    }
}

extension Result {
    var error: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
