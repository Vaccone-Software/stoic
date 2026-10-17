@testable import Stoic
import StoicTesting
import Testing

@Suite("Spans")
struct SpanTests {
    struct Boom: Error {}

    func fields(of event: Event) -> [String: String] {
        Dictionary(uniqueKeysWithValues: event.fields.map { ($0.key, "\($0.value)") })
    }

    /// The `span.started` and `span.ended` events, by span name.
    func ended(_ events: RecordingInstrumentation, _ name: String) -> Event? {
        events.events(named: "span.ended").first { fields(of: $0)["name"] == name }
    }

    func started(_ events: RecordingInstrumentation, _ name: String) -> Event? {
        events.events(named: "span.started").first { fields(of: $0)["name"] == name }
    }

    @Test(.failureMode("design/11", "no sink wants debug events"))
    func withoutAnObserverTheOperationJustRuns() async throws {
        let clock = TestClock()
        let none = await withAmbient({ $0.instrumentation = NoInstrumentation(); $0.clock = AnyClock(clock) }) {
            await withSpan("quiet") { Span.current?.name }
        }
        #expect(none == nil, "no span is bound when nobody listens")

        // A sink that wants info but not debug (the default OSLog's shape) is no observer either.
        let events = RecordingInstrumentation()
        let filtering = FilteringInstrumentation(minimum: .info, wrapping: events)
        let current = await withAmbient({ $0.instrumentation = filtering }) {
            await withSpan("quiet") { Span.current }
        }
        #expect(current == nil)
        #expect(events.events.isEmpty)
        #expect(filtering.recordCalls == 0)
    }

    @Test(.stoic(seed: 3), .failureMode("design/11", "the clock is a test clock"))
    func aSpanLastsExactlyAsLongAsTheTestClockSaysAndEmitsBothEvents() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, seed: 3, events: events) {
            let work = Task {
                try await withSpan("fetch", [.init("kind", .string("user"), privacy: .public), .init("page", .int(2))]) {
                    try await Ambient.sleep(for: .seconds(3))
                }
            }
            await clock.waitForSleepers(count: 1)
            await clock.advance(by: .seconds(3))
            try await work.value
        }
        #expect(events.names == ["span.started", "span.ended"])
        let start = try #require(events.events.first)
        let end = try #require(events.events.last)
        #expect(start.level == .debug)
        #expect(fields(of: start)["name"] == "fetch")
        #expect(fields(of: start)["kind"] == "user")
        #expect(fields(of: start)["page"] == "2")
        #expect(start["parent"] == nil, "a root span has no parent")
        #expect(fields(of: start)["span"] == fields(of: start)["trace"], "the trace is the root's id")
        #expect(fields(of: end)["span"] == fields(of: start)["span"])
        #expect(fields(of: end)["status"] == "ok")
        #expect(fields(of: end)["duration"] == "\(Duration.seconds(3))")
        #expect(end.fields.first { $0.key == "name" }?.privacy == .public)
        #expect(end.fields.first { $0.key == "span" }?.privacy == .public)
        #expect(end.span == start.span)
    }

    @Test(.stoic(seed: 4)) func idsAreReproducibleFromTheSeed() async throws {
        func run() async throws -> [String] {
            let events = RecordingInstrumentation()
            await withTestAmbient(clock: ImmediateClock(), seed: 9, events: events) {
                await withSpan("a") { await withSpan("b") {} }
            }
            return events.events.map { fields(of: $0)["span"] ?? "" }
        }
        let first = try await run()
        let second = try await run()
        #expect(first == second)
        #expect(Set(first).count == 2, "two spans, two ids")
        #expect(first.allSatisfy { $0.count == 16 })
    }

    @Test(.stoic(seed: 5), .failureMode("design/11", "a span is opened inside another"))
    func aNestedSpanNamesItsParentAndSharesTheTrace() async throws {
        let events = RecordingInstrumentation()
        await withTestAmbient(clock: ImmediateClock(), seed: 5, events: events) {
            await withSpan("outer") {
                await withSpan("inner") {
                    #expect(Span.current?.name == "inner")
                }
                #expect(Span.current?.name == "outer", "the inner span ends and the outer one is current again")
            }
            #expect(Span.current == nil)
        }
        let outer = try #require(started(events, "outer"))
        let inner = try #require(started(events, "inner"))
        #expect(fields(of: inner)["parent"] == fields(of: outer)["span"])
        #expect(fields(of: inner)["trace"] == fields(of: outer)["trace"])
        #expect(inner.span?.parentID == outer.span?.id)
        #expect(events.names == ["span.started", "span.started", "span.ended", "span.ended"])
        #expect(fields(of: try #require(ended(events, "inner")))["parent"] == fields(of: outer)["span"])
    }

    @Test(.stoic(seed: 6), .failureMode("design/11", "a Stoic scope forks work inside a span"))
    func spansReachTheForksOfAStoicScope() async throws {
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: ImmediateClock(), seed: 6, events: events) {
            try await withSpan("request") {
                // A scope cancels its forks when its body ends, and a fork
                // cancelled before it began runs none of its work: the body
                // waits until both have run.
                let ran = (a: AsyncGate(), b: AsyncGate())
                try await withTaskScope(label: "work") { scope in
                    scope.fork(label: "a") { await withSpan("child.a") {}; ran.a.open() }
                    scope.fork(label: "b") { await withSpan("child.b") {}; ran.b.open() }
                    await ran.a.wait()
                    await ran.b.wait()
                }
                async let sibling: Void = withSpan("child.async") {}
                await sibling
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await withSpan("child.group") {} }
                    await group.waitForAll()
                }
            }
        }
        let root = try #require(started(events, "request"))
        for name in ["child.a", "child.b", "child.async", "child.group"] {
            let child = try #require(started(events, name), "\(name) was recorded")
            #expect(fields(of: child)["parent"] == fields(of: root)["span"], "\(name) is a child of the request")
            #expect(fields(of: child)["trace"] == fields(of: root)["trace"])
        }
    }

    @Test(.stoic(seed: 7), .failureMode("design/11", "the operation throws"))
    func anErrorIsTheSpansStatusAndIsRethrownUnchanged() async throws {
        let events = RecordingInstrumentation()
        await withTestAmbient(clock: ImmediateClock(), seed: 7, events: events) {
            await #expect(throws: Boom.self) {
                try await withSpan("fails") { () throws(Boom) in throw Boom() }
            }
        }
        let end = try #require(ended(events, "fails"))
        #expect(fields(of: end)["status"] == "error")
        #expect(fields(of: end)["error"]?.contains("Boom") == true)
        #expect(end.fields.first { $0.key == "error" }?.privacy == .private, "the description may carry user data")
    }

    @Test(.stoic(seed: 8), .failureMode("design/11", "the operation is cancelled"))
    func cancellationIsNotAnError() async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        let task = Task {
            try await withTestAmbient(clock: clock, seed: 8, events: events) {
                try await withSpan("sleeps") { try await Ambient.sleep(for: .seconds(60)) }
            }
        }
        await clock.waitForSleepers(count: 1)
        task.cancel()
        _ = try? await task.value
        let end = try #require(ended(events, "sleeps"))
        #expect(fields(of: end)["status"] == "cancelled")
        #expect(end["error"] == nil)

        // A cancelled rejection from a policy, and a Report of a cancellation, are cancellations too.
        let rejected = RecordingInstrumentation()
        await withTestAmbient(clock: ImmediateClock(), seed: 8, events: rejected) {
            _ = try? await withSpan("rejected") { () throws(PolicyError<Boom>) in throw .rejected(Rejection(.cancelled)) }
            _ = try? await withSpan("reported") { () throws(Report) in throw Report(CancellationError()) }
        }
        #expect(fields(of: try #require(ended(rejected, "rejected")))["status"] == "cancelled")
        #expect(fields(of: try #require(ended(rejected, "reported")))["status"] == "cancelled")
    }

    @Test(.stoic(seed: 9), .failureMode("design/11", "an event is recorded inside a span"))
    func anEventRecordedInsideASpanCarriesIt() async throws {
        let events = RecordingInstrumentation()
        await withTestAmbient(clock: ImmediateClock(), seed: 9, events: events) {
            Ambient.record(Event("race.won", level: .debug))
            await withSpan("outer") {
                Ambient.record(Event("race.won", level: .debug))
            }
        }
        let won = events.events(named: "race.won")
        #expect(won.count == 2)
        #expect(won[0].span == nil)
        #expect(won[1].span == started(events, "outer")?.span)
        #expect(won[1].span != nil)
    }
}

/// A sink that keeps only events at or above `minimum`, and counts what reaches it.
final class FilteringInstrumentation: Instrumentation, Sendable {
    let minimum: Event.Level
    let inner: RecordingInstrumentation
    private let calls = SendableBox(0)

    init(minimum: Event.Level, wrapping inner: RecordingInstrumentation) {
        self.minimum = minimum
        self.inner = inner
    }

    var recordCalls: Int { calls.value }

    func isEnabled(_ level: Event.Level) -> Bool { level >= minimum }

    func record(_ event: Event) {
        calls.mutate { $0 += 1 }
        inner.record(event)
    }
}
