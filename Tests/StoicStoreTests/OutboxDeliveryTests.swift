import Foundation
import Stoic
@testable import StoicStore
import StoicTesting
import Testing

/// What a delivery says about its entry, what becomes of an entry that cannot
/// be sent, and delivering one entry at a time (design/15, Outbox).
@Suite("Outbox delivery results")
struct OutboxDeliveryTests {
    func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    /// A new policy each time: each one has its own retry budget, which a
    /// shared one would spend across every test.
    static var quick: DeliveryPolicy { DeliveryPolicy(schedule: .fixed(.seconds(1)).attempts(3), budget: .unlimited) }

    func open(
        _ disk: SimulatedFileSystem, policy: DeliveryPolicy = OutboxDeliveryTests.quick, threshold: Int = 64 * 1024,
        codec: OutboxCodec<String> = .utf8
    ) throws -> Outbox<String> {
        try Outbox<String>.open(at: "/d/outbox", codec: codec, fileSystem: disk, policy: policy, compactionThreshold: threshold)
    }

    /// Items that start with `!` no longer decode.
    static let pickyCodec = OutboxCodec<String>(
        encode: { Array($0.utf8) },
        decode: { bytes in
            let text = String(decoding: bytes, as: UTF8.self)
            if text.hasPrefix("!") { throw Rejected() }
            return text
        })

    /// One word for what an outcome was, since an outcome carries an error.
    static func kind(_ outcome: DeliveryOutcome) -> String {
        switch outcome {
        case .delivered: "delivered"
        case .discarded(let reason): "discarded:\(reason.kind):\(reason)"
        case .failed(_, let attempts): "failed:\(attempts)"
        case .kept: "kept"
        case .notPending: "notPending"
        }
    }

    static func text(_ event: Event, _ key: String) -> String? {
        if case .string(let value)? = event[key] { value } else { nil }
    }

    /// Yields until `count` `deliver` calls are waiting their turn: the call
    /// has met the delivery in progress, and the test may let that finish.
    static func untilWaiting(_ count: Int, on outbox: Outbox<String>, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100_000 {
            if await outbox.waitingDeliveries >= count { return }
            await Task.yield()
        }
        Issue.record("\(count) deliveries never began to wait", sourceLocation: sourceLocation)
    }

    // MARK: A delivery says what became of its entry

    @Test(.failureMode("design/15", "the closure returns .discard"))
    func aDiscardedEntryLeavesTheQueueDurablyAndIsNotCountedAsDelivered() async throws {
        let disk = try disk()
        let events = RecordingInstrumentation()
        let outbox = try open(disk)
        let bad = try await outbox.enqueue("bad")
        let good = try await outbox.enqueue("good")
        let tries = SendableBox(0)
        let report = try await withTestAmbient(clock: ImmediateClock(), events: events) {
            try await outbox.deliverPending { entry in
                guard entry.item == "bad" else { return .delivered }
                tries.mutate { $0 += 1 }
                if tries.value < 3 { throw Unavailable() }
                return .discard(reason: "http 400")
            }
        }
        // Retried as any failure is until it said so; then dropped, and the run went on (stopAtFirst).
        #expect(report.discarded.map(\.key) == [bad])
        #expect(report.discarded.first?.reason == .refused("http 400"))
        #expect(report.discarded.first?.attempts == 3)
        #expect(report.delivered == [good], "a refusal is not a delivery")
        #expect(report.failed.isEmpty && report.kept.isEmpty)
        #expect(report.remaining == 0)
        let recorded = events.events(named: "store.outbox_discarded")
        #expect(recorded.count == 1)
        #expect(recorded.first.flatMap { Self.text($0, "kind") } == "refused")
        #expect(recorded.first.flatMap { Self.text($0, "reason") } == "http 400")
        // Durable: a relaunch finds nothing to send.
        disk.crash()
        #expect(await (try open(disk)).pendingCount == 0)
    }

    @Test(.failureMode("design/15", "the closure throws a Retryable error saying .stop"))
    func aPermanentErrorIsStillOnlyAFailureNotADiscard() async throws {
        let outbox = try open(try disk())
        try await outbox.enqueue("a")
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in throw Rejected() }
        }
        #expect(report.failed.count == 1 && report.failed.first?.attempts == 1)
        #expect(report.discarded.isEmpty)
        #expect(await outbox.pendingCount == 1, "only a returned .discard drops an entry")
    }

    @Test(.failureMode("design/15", "the closure returns .keep"))
    func aKeptEntryStaysPendingWithoutAnErrorAndStopsAStopAtFirstRun() async throws {
        let events = RecordingInstrumentation()
        let outbox = try open(try disk())
        let first = try await outbox.enqueue("first")
        try await outbox.enqueue("second")
        let seen = SendableBox<[String]>([])
        let report = try await withTestAmbient(clock: ImmediateClock(), events: events) {
            try await outbox.deliverPending { entry in
                seen.mutate { $0.append(entry.item) }
                return .keep
            }
        }
        #expect(seen.value == ["first"], "not tried again in this run, and the second did not overtake it")
        #expect(report.kept == [first])
        #expect(report.failed.isEmpty && report.delivered.isEmpty && report.discarded.isEmpty)
        #expect(report.remaining == 2)
        #expect(events.events(named: "store.outbox_kept").count == 1)
    }

    @Test(.failureMode("design/15", "the closure returns .keep"))
    func aKeptEntryDoesNotStopAContinueWithNextRun() async throws {
        let outbox = try open(try disk(), policy: DeliveryPolicy(schedule: .immediate.attempts(1), onFailure: .continueWithNext))
        let first = try await outbox.enqueue("first")
        let second = try await outbox.enqueue("second")
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in entry.item == "first" ? .keep : .delivered }
        }
        #expect(report.kept == [first])
        #expect(report.delivered == [second])
    }

    // MARK: Entries that cannot be sent

    @Test(.failureMode("design/15", "an item no longer decodes"))
    func byDefaultAnUndecodableEntryIsKeptAndHoldsAStopAtFirstQueue() async throws {
        let disk = try disk()
        let writer = try open(disk)
        let old = try await writer.enqueue("!written by a newer version")
        try await writer.enqueue("fine")
        try await writer.close()
        let outbox = try open(disk, codec: Self.pickyCodec)
        let seen = SendableBox<[String]>([])
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in
                seen.mutate { $0.append(entry.item) }
                return .delivered
            }
        }
        #expect(report.failed.map(\.key) == [old])
        #expect(report.failed.first?.attempts == 0)
        #expect((report.failed.first?.error as? StoreError)?.kind == .corrupt)
        #expect(seen.value.isEmpty, "stopAtFirst: nothing overtakes it")
        #expect(report.remaining == 2, "kept: a newer version of the app may be able to read it")
    }

    @Test(.failureMode("design/15", "an item no longer decodes and onUndecodable is .discard"))
    func anUndecodableEntryCanBeDiscardedAndTheQueueGoesOn() async throws {
        let disk = try disk()
        let events = RecordingInstrumentation()
        let writer = try open(disk)
        let old = try await writer.enqueue("!unreadable")
        let fine = try await writer.enqueue("fine")
        try await writer.close()
        var policy = Self.quick
        policy.onUndecodable = .discard
        let outbox = try open(disk, policy: policy, codec: Self.pickyCodec)
        let report = try await withTestAmbient(clock: ImmediateClock(), events: events) {
            try await outbox.deliverPending { _ in .delivered }
        }
        #expect(report.discarded.map(\.key) == [old])
        #expect(report.discarded.first?.reason == .undecodable)
        #expect(report.discarded.first?.attempts == 0)
        #expect(report.failed.isEmpty)
        #expect(report.delivered == [fine], "under stopAtFirst, too")
        #expect(events.events(named: "store.outbox_discarded").first.flatMap { Self.text($0, "kind") } == "undecodable")
        disk.crash()
        #expect(await (try open(disk, codec: Self.pickyCodec)).pendingCount == 0)
    }

    // MARK: Expiry

    /// A wall clock the test sets.
    func expiring(_ now: SendableBox<Duration>, maxAge: Duration = .seconds(3600)) -> DeliveryPolicy {
        DeliveryPolicy(
            schedule: .immediate.attempts(1), expiry: .init(maxAge: maxAge, wallClock: { now.value }))
    }

    static let epoch = Duration.seconds(1_800_000_000)

    @Test(.failureMode("design/15", "an entry is older than the policy's expiry when a run reaches it"))
    func anEntryOlderThanTheExpiryIsDiscardedUnsent() async throws {
        let now = SendableBox(Self.epoch)
        let outbox = try open(try disk(), policy: expiring(now))
        let old = try await outbox.enqueue("old")
        now.mutate { $0 += .seconds(1800) }
        let young = try await outbox.enqueue("young")
        now.mutate { $0 += .seconds(1900) }   // old is 3700 s old, young 1900 s
        let seen = SendableBox<[String]>([])
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { entry in
                seen.mutate { $0.append(entry.item) }
                return .delivered
            }
        }
        #expect(seen.value == ["young"], "an expired entry is never sent")
        #expect(report.discarded.map(\.key) == [old])
        #expect(report.discarded.first?.reason == .expired)
        #expect(report.discarded.first?.attempts == 0)
        #expect(report.delivered == [young])
        #expect(report.remaining == 0)
    }

    @Test func theLimitIsAgeAtLeastMaxAgeAndAClockThatWentBackwardsExpiresNothing() {
        let maxAge = Duration.seconds(3600)
        #expect(Outbox<String>.isExpired(enqueuedAt: 0, now: 3_600_000, maxAge: maxAge), "exactly maxAge old")
        #expect(!Outbox<String>.isExpired(enqueuedAt: 0, now: 3_599_999, maxAge: maxAge))
        #expect(!Outbox<String>.isExpired(enqueuedAt: 5_000_000, now: 1_000, maxAge: maxAge), "enqueued in the future")
        #expect(!Outbox<String>.isExpired(enqueuedAt: .min, now: .max, maxAge: maxAge), "arithmetic that overflows is not an expiry")
    }

    @Test(.failureMode("design/15", "the wall clock is behind an entry's enqueue time"))
    func anEntryEnqueuedInTheFutureByAClockThatMovedBackIsNotExpired() async throws {
        let now = SendableBox(Self.epoch)
        let outbox = try open(try disk(), policy: expiring(now))
        let key = try await outbox.enqueue("a")
        now.mutate { $0 -= .seconds(86_400) }   // the user set the clock back a day
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in .delivered }
        }
        #expect(report.delivered == [key] && report.discarded.isEmpty)
    }

    @Test(.failureMode("design/15", "an expiring outbox is relaunched or compacted"))
    func theTimeAnEntryWasEnqueuedSurvivesARelaunch() async throws {
        let disk = try disk()
        let now = SendableBox(Self.epoch)
        var outbox = try open(disk, policy: expiring(now))
        let key = try await outbox.enqueue("a")
        try await outbox.close()
        now.mutate { $0 += .seconds(2 * 3600) }
        outbox = try open(disk, policy: expiring(now))
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in .delivered }
        }
        #expect(report.discarded.map(\.key) == [key])
        #expect(report.discarded.first?.reason == .expired)
    }

    @Test(.failureMode("design/15", "an expiring outbox is relaunched or compacted"))
    func theTimeAnEntryWasEnqueuedSurvivesACompaction() async throws {
        let disk = try disk()
        let now = SendableBox(Self.epoch)
        var outbox = try open(disk, policy: expiring(now), threshold: 1)
        let key = try await outbox.enqueue("a")
        // A run that fails folds the log into a snapshot (the threshold is one byte).
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in throw Unavailable() }
        }
        #expect(disk.contents(of: "/d/outbox.snapshot") != nil)
        try await outbox.close()
        // The enqueue now exists only in the snapshot.
        now.mutate { $0 += .seconds(2 * 3600) }
        outbox = try open(disk, policy: expiring(now))
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in .delivered }
        }
        #expect(report.discarded.map(\.key) == [key])
        #expect(report.discarded.first?.reason == .expired)
    }

    @Test(.failureMode("design/15", "an entry was enqueued with no expiry set"))
    func anEntryEnqueuedBeforeExpiryWasSetNeverExpires() async throws {
        let disk = try disk()
        let now = SendableBox(Self.epoch)
        var outbox = try open(disk)
        let key = try await outbox.enqueue("old")
        try await outbox.close()
        now.mutate { $0 += .seconds(1000 * 3600) }
        outbox = try open(disk, policy: expiring(now))
        let report = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in .delivered }
        }
        #expect(report.delivered == [key] && report.discarded.isEmpty)
    }

    @Test(.failureMode("design/15", "an outbox that sets no expiry"))
    func anOutboxWithNoExpiryWritesTheFormatsEveryEarlierReleaseReads() async throws {
        let disk = try disk()
        let outbox = try open(disk, threshold: 1)
        try await outbox.enqueue("a")
        try await outbox.enqueue("b")
        let journal = try Journal.open(at: "/d/outbox", fileSystem: disk)
        var records = try journal.replay().records
        #expect(records.map { $0.bytes[0] } == [0x01, 0x01], "enqueue records as ever")
        try journal.close()
        _ = try await withTestAmbient(clock: ImmediateClock()) {
            try await outbox.deliverPending { _ in throw Unavailable() }
        }
        try await outbox.close()
        let reader = try Journal.open(at: "/d/outbox", fileSystem: disk)
        let snapshot = try #require(try reader.replay().snapshot)
        #expect(snapshot.bytes[3] & 0x80 == 0, "no timestamp flag in the snapshot's count")
        records = try reader.replay().records
        #expect(records.isEmpty)
        try reader.close()

        // With expiry, the same entries carry the time.
        let stamped = try Outbox<String>.open(
            at: "/d/stamped", codec: .utf8, fileSystem: disk, policy: expiring(SendableBox(Self.epoch)))
        try await stamped.enqueue("c")
        let stampedJournal = try Journal.open(at: "/d/stamped", fileSystem: disk)
        #expect(try stampedJournal.replay().records.map { $0.bytes[0] } == [0x03])
    }

    // MARK: One entry

    @Test(.failureMode("design/15", "deliver(_:using:) names a pending entry"))
    func deliveringOneEntryAttemptsThatEntryAloneAndSaysWhatHappened() async throws {
        for (label, expected, stays) in [
            ("delivered", "delivered", false), ("discard", "discarded:refused:bad request", false),
            ("fail", "failed:3", true), ("keep", "kept", true),
        ] {
            let events = RecordingInstrumentation()
            let outbox = try open(try disk())
            let first = try await outbox.enqueue("first")
            let target = try await outbox.enqueue("target")
            let third = try await outbox.enqueue("third")
            let seen = SendableBox<[String]>([])
            let outcome = try await withTestAmbient(clock: ImmediateClock(), events: events) {
                try await outbox.deliver(target) { entry in
                    seen.mutate { $0.append(entry.item) }
                    switch label {
                    case "discard": return .discard(reason: "bad request")
                    case "fail": throw Unavailable()
                    case "keep": return .keep
                    default: return .delivered
                    }
                }
            }
            #expect(Self.kind(outcome) == expected, "\(label)")
            #expect(seen.value.count == (label == "fail" ? 3 : 1), "\(label): the policy's schedule, and only this entry")
            #expect(Set(seen.value) == ["target"], "\(label)")
            let rest = await outbox.pendingKeys
            #expect(rest == (stays ? [first, target, third] : [first, third]), "\(label): the others were not touched")
        }
    }

    @Test(.failureMode("design/15", "deliver(_:using:) names an entry that is not pending"))
    func deliveringAnEntryThatIsNotPendingAttemptsNothing() async throws {
        let outbox = try open(try disk())
        let key = try await outbox.enqueue("a")
        let calls = SendableBox(0)
        let first = try await outbox.deliver(key) { _ in .delivered }
        #expect(Self.kind(first) == "delivered")
        for unknown in [key, IdempotencyKey.random()] {
            let outcome = try await outbox.deliver(unknown) { _ in
                calls.mutate { $0 += 1 }
                return .delivered
            }
            #expect(Self.kind(outcome) == "notPending")
        }
        #expect(calls.value == 0)
    }

    @Test(.failureMode("design/15", "a second deliverPending starts during a run"))
    func aRunThatStartsWhileOneEntryIsBeingDeliveredDoesNothing() async throws {
        let outbox = try open(try disk())
        let key = try await outbox.enqueue("a")
        let started = TestGate()
        let release = TestGate()
        let single = Task {
            try await withTestAmbient(clock: ImmediateClock()) {
                try await outbox.deliver(key) { _ in
                    started.open()
                    await release.wait()
                    return .delivered
                }
            }
        }
        await started.wait()
        let run = try await outbox.deliverPending { _ in
            Issue.record("attempted twice at once")
            return .delivered
        }
        #expect(run.wasAlreadyRunning && run.remaining == 1)
        release.open()
        #expect(Self.kind(try await single.value) == "delivered")
    }

    /// A run held inside its first entry, and what to do while it is.
    struct HeldRun {
        let outbox: Outbox<String>
        let started = TestGate()
        let release = TestGate()
        let active = SendableBox(0)
        let peak = SendableBox(0)
        let attempts = SendableBox<[String]>([])

        /// An attempt that notes itself, so a second at once shows.
        func note(_ entry: Outbox<String>.Entry) {
            active.mutate { $0 += 1 }
            peak.mutate { $0 = max($0, active.value) }
            attempts.mutate { $0.append(entry.item) }
        }

        func settle() { active.mutate { $0 -= 1 } }

        func start(holding item: String) -> Task<Outbox<String>.DeliveryReport, any Error> {
            Task { [self] in
                try await withTestAmbient(clock: ImmediateClock()) {
                    try await outbox.deliverPending { entry in
                        note(entry)
                        defer { settle() }
                        if entry.item == item {
                            started.open()
                            await release.wait()
                        }
                        return .delivered
                    }
                }
            }
        }

        func deliver(_ key: IdempotencyKey, answering result: DeliveryResult = .delivered) -> Task<DeliveryOutcome, any Error> {
            Task { [self] in
                try await withTestAmbient(clock: ImmediateClock()) {
                    try await outbox.deliver(key) { entry in
                        note(entry)
                        defer { settle() }
                        return result
                    }
                }
            }
        }
    }

    @Test(.failureMode("design/15", "deliver(_:using:) is called while a run is going"), .timeLimit(.minutes(1)))
    func aDeliveryWaitsForTheRunGetsItsOutcomeIfItAttemptedTheEntryAndAttemptsOneItDidNot() async throws {
        let outbox = try open(try disk())
        let held = HeldRun(outbox: outbox)
        let inRun = try await outbox.enqueue("in the run")
        let run = held.start(holding: "in the run")
        await held.started.wait()
        let later = try await outbox.enqueue("enqueued mid-run")   // not in this run
        let ofInRun = held.deliver(inRun)
        let ofLater = held.deliver(later)
        await Self.untilWaiting(2, on: outbox)
        #expect(held.attempts.value == ["in the run"], "nothing else is attempted while the run goes")
        held.release.open()

        let report = try await run.value
        #expect(report.delivered == [inRun], "the entry enqueued mid-run was not in the run")
        #expect(Self.kind(try await ofInRun.value) == "delivered", "the run's outcome, with no second attempt")
        #expect(Self.kind(try await ofLater.value) == "delivered")
        #expect(held.attempts.value == ["in the run", "enqueued mid-run"], "each attempted once")
        #expect(held.peak.value == 1, "never two attempts at once")
        #expect(await outbox.pendingCount == 0)
    }

    @Test(.failureMode("design/15", "two deliver(_:using:) calls name one entry"), .timeLimit(.minutes(1)))
    func twoCallersForOneEntryShareOneAttemptAndItsOutcome() async throws {
        let outbox = try open(try disk())
        let held = HeldRun(outbox: outbox)
        let busy = try await outbox.enqueue("busy")
        let run = held.start(holding: "busy")
        await held.started.wait()
        let target = try await outbox.enqueue("target")
        // Kept, so the entry is still pending when the second caller's turn comes:
        // it must not be attempted again for it.
        let first = held.deliver(target, answering: .keep)
        let second = held.deliver(target, answering: .keep)
        await Self.untilWaiting(2, on: outbox)
        held.release.open()
        _ = try await run.value
        #expect(Self.kind(try await first.value) == "kept")
        #expect(Self.kind(try await second.value) == "kept")
        #expect(held.attempts.value == ["busy", "target"], "one attempt of the target")
        #expect(held.peak.value == 1)
        #expect(await outbox.pendingKeys == [target])
        _ = busy
    }

    @Test(.failureMode("design/15", "deliver(_:using:) is cancelled while it waits"), .timeLimit(.minutes(1)))
    func aDeliveryCancelledWhileWaitingLeavesTheRunAndTheEntryAlone() async throws {
        let outbox = try open(try disk())
        let held = HeldRun(outbox: outbox)
        try await outbox.enqueue("busy")
        let run = held.start(holding: "busy")
        await held.started.wait()
        let target = try await outbox.enqueue("target")
        let waiting = held.deliver(target)
        await Self.untilWaiting(1, on: outbox)
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await outbox.waitingDeliveries == 0)
        held.release.open()
        let report = try await run.value
        #expect(report.delivered.count == 1)
        #expect(await outbox.pendingKeys == [target], "never attempted")
        // The turn was not leaked: the next delivery goes through.
        let outcome = try await outbox.deliver(target) { _ in .delivered }
        #expect(Self.kind(outcome) == "delivered")
    }

    @Test func aDeliveryThatIsAlreadyCancelledDoesNotTakeTheTurn() async throws {
        let outbox = try open(try disk())
        let key = try await outbox.enqueue("a")
        let go = TestGate()
        let task = Task {
            await go.wait()
            return try await outbox.deliver(key) { _ in
                Issue.record("attempted for a cancelled caller")
                return .delivered
            }
        }
        task.cancel()
        go.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        let outcome = try await outbox.deliver(key) { _ in .delivered }
        #expect(Self.kind(outcome) == "delivered", "the turn is free")
    }

    @Test func deliveringAnExpiredEntryDiscardsItAsARunWouldWithoutSendingIt() async throws {
        let now = SendableBox(Self.epoch)
        let outbox = try open(try disk(), policy: expiring(now))
        let key = try await outbox.enqueue("old")
        now.mutate { $0 += .seconds(7200) }
        let outcome = try await outbox.deliver(key) { _ in
            Issue.record("an expired entry was sent")
            return .delivered
        }
        #expect(Self.kind(outcome) == "discarded:expired:expired")
        #expect(await outbox.pendingCount == 0)
    }

    @Test func deliveringAnUndecodableEntryFollowsTheUndecodablePolicy() async throws {
        var discarding = Self.quick
        discarding.onUndecodable = .discard
        for (policy, expected, remaining) in [
            (discarding, "discarded:undecodable:undecodable", 0), (Self.quick, "failed:0", 1),
        ] {
            let outbox = try open(try disk(), policy: policy, codec: Self.pickyCodec)
            let key = try await outbox.enqueue("!bad")
            let outcome = try await outbox.deliver(key) { _ in
                Issue.record("an undecodable entry was sent")
                return .delivered
            }
            #expect(Self.kind(outcome) == expected)
            #expect(await outbox.pendingCount == remaining)
        }
    }
}
