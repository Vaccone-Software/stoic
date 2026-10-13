#if STOIC_LOGGING
import Logging
import Stoic
import StoicObservability
import Synchronization
import Testing

@Suite("swift-log adapter")
struct SwiftLogTests {
    final class Capture: LogHandler, @unchecked Sendable {   // stoic:allow(unchecked-sendable): swift-log's LogHandler is a value-ish protocol; this test handler is only read after logging finishes
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        let lines = Mutex<[(Logger.Level, String, Logger.Metadata)]>([])
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(event: LogEvent) {
            lines.withLock { $0.append((event.level, event.message.description, event.metadata ?? [:])) }
        }
    }

    @Test func eventsBecomeLogMessagesWithPrivateFieldsRedacted() {
        let capture = Capture()
        let logger = Logger(label: "test") { _ in capture }
        let sink = SwiftLogInstrumentation(logger: logger)
        sink.record(Event("retry.exhausted", level: .notice, label: "sync", fields: [
            .init("attempt", .int(3)),
            .init("error", .string("token=hunter2")),
        ]))
        let lines = capture.lines.withLock { $0 }
        #expect(lines.count == 1)
        #expect(lines.first?.0 == .notice)
        #expect(lines.first?.1 == "retry.exhausted")
        #expect(lines.first?.2["attempt"] == "3")
        #expect(lines.first?.2["error"] == "<private>")
        #expect(lines.first?.2["label"] == "sync")
    }
}
#endif

#if STOIC_LOGGING
@Suite("swift-log adapter: spans")
struct SwiftLogSpanTests {
    func capture() -> (SwiftLogTests.Capture, SwiftLogInstrumentation) {
        let capture = SwiftLogTests.Capture()
        let logger = Logger(label: "test") { _ in capture }
        return (capture, SwiftLogInstrumentation(logger: logger))
    }

    @Test
    func aSpanBecomesMetadataOnItsMessagesAndOnEventsInsideIt() async throws {
        let (capture, sink) = capture()
        let clock = ManualClock()
        await withAmbient({ $0.instrumentation = sink; $0.clock = AnyClock(clock); $0.random = .seeded(1) }) {
            await withSpan("outer", [.init("user", .string("ada"), privacy: .public)]) {
                Ambient.record(Event("race.won", level: .info, label: "inside"))
                await withSpan("inner") {}
            }
            Ambient.record(Event("race.won", level: .info, label: "outside"))
        }
        let lines = capture.lines.withLock { $0 }
        #expect(lines.map(\.1) == ["span.started", "race.won", "span.started", "span.ended", "span.ended", "race.won"])

        let outer = lines[0].2
        let inside = lines[1].2
        let inner = lines[2].2
        #expect(outer["name"] == "outer")
        #expect(outer["user"] == "ada")
        #expect(outer["parent"] == nil)
        #expect(inside["label"] == "inside")
        #expect(inside["span"] == outer["span"])
        #expect(inside["trace"] == outer["trace"])
        #expect(inner["parent"] == outer["span"])
        #expect(inner["trace"] == outer["trace"])
        #expect(lines[5].2["span"] == nil, "outside any span there is no span metadata")
    }

    @Test
    func anEndedSpanReportsStatusAndSecondsAndRedactsTheError() async throws {
        let (capture, sink) = capture()
        let clock = ManualClock()
        struct Boom: Error {}
        await withAmbient({ $0.instrumentation = sink; $0.clock = AnyClock(clock) }) {
            _ = try? await withSpan("fetch") { () async throws in
                clock.advance(by: .milliseconds(1500))
                throw Boom()
            }
        }
        let ended = try #require(capture.lines.withLock { $0 }.last).2
        #expect(ended["status"] == "error")
        #expect(ended["duration"] == "1.5")
        #expect(ended["error"] == "<private>")
    }
}
#endif

#if STOIC_METRICS
import Metrics
import Stoic
import StoicObservability
import Synchronization
import Testing

/// Keeps the nanoseconds every timer was given, by label and dimensions.
final class RecordingMetrics: MetricsFactory, Sendable {
    struct Series: Hashable {
        let label: String
        let dimensions: [String]
    }

    private let timers = Mutex<[Series: [Int64]]>([:])
    private let counters = Mutex<[Series: Int64]>([:])

    static let shared: RecordingMetrics = {
        let factory = RecordingMetrics()
        MetricsSystem.bootstrap(factory)
        return factory
    }()

    func timer(_ label: String, _ dimensions: String...) -> [Int64] {
        timers.withLock { $0[Series(label: label, dimensions: dimensions)] ?? [] }
    }

    func count(_ label: String, _ dimensions: String...) -> Int64 {
        counters.withLock { $0[Series(label: label, dimensions: dimensions)] ?? 0 }
    }

    private static func flatten(_ dimensions: [(String, String)]) -> [String] { dimensions.map { "\($0.0)=\($0.1)" } }

    private final class Handler: CounterHandler, TimerHandler, RecorderHandler, Sendable {
        let record: @Sendable (Int64) -> Void
        init(_ record: @escaping @Sendable (Int64) -> Void) { self.record = record }
        func increment(by amount: Int64) { record(amount) }
        func reset() {}
        func recordNanoseconds(_ duration: Int64) { record(duration) }
        func record(_ value: Int64) { self.record(value) }
        func record(_ value: Double) { self.record(Int64(value)) }
    }

    func makeCounter(label: String, dimensions: [(String, String)]) -> any CounterHandler {
        let series = Series(label: label, dimensions: Self.flatten(dimensions))
        return Handler { [self] amount in counters.withLock { $0[series, default: 0] += amount } }
    }

    func makeTimer(label: String, dimensions: [(String, String)]) -> any TimerHandler {
        let series = Series(label: label, dimensions: Self.flatten(dimensions))
        return Handler { [self] nanoseconds in timers.withLock { $0[series, default: []].append(nanoseconds) } }
    }

    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> any RecorderHandler {
        Handler { _ in }
    }

    func destroyCounter(_ handler: any CounterHandler) {}
    func destroyTimer(_ handler: any TimerHandler) {}
    func destroyRecorder(_ handler: any RecorderHandler) {}
}

@Suite("swift-metrics adapter: spans")
struct SwiftMetricsSpanTests {
    struct Boom: Error {}

    @Test
    func aSpanIsATimerNamedAndDimensionedByNameAndStatus() async throws {
        let metrics = RecordingMetrics.shared
        let clock = ManualClock()
        await withAmbient({ $0.instrumentation = SwiftMetricsInstrumentation(); $0.clock = AnyClock(clock) }) {
            await withSpan("metrics.ok") { clock.advance(by: .milliseconds(2500)) }
        }
        #expect(metrics.timer("stoic_span_duration", "name=metrics.ok", "status=ok") == [2_500_000_000])
        #expect(metrics.count("stoic_events_total", "name=span.ended", "level=debug") >= 1)
    }

    @Test
    func failedAndCancelledSpansAreSeparateSeries() async throws {
        let metrics = RecordingMetrics.shared
        await withAmbient({ $0.instrumentation = SwiftMetricsInstrumentation(); $0.clock = AnyClock(ManualClock()) }) {
            _ = try? await withSpan("metrics.fail") { () throws(Boom) in throw Boom() }
            _ = try? await withSpan("metrics.cancel") { () throws(CancellationError) in throw CancellationError() }
        }
        #expect(metrics.timer("stoic_span_duration", "name=metrics.fail", "status=error").count == 1)
        #expect(metrics.timer("stoic_span_duration", "name=metrics.cancel", "status=cancelled").count == 1)
    }

    @Test func aNilTimerLabelTurnsSpanTimersOff() async {
        let metrics = RecordingMetrics.shared
        await withAmbient({ $0.instrumentation = SwiftMetricsInstrumentation(spanTimerLabel: nil) }) {
            await withSpan("metrics.off") {}
        }
        #expect(metrics.timer("stoic_span_duration", "name=metrics.off", "status=ok").isEmpty)
    }
}
#endif

#if STOIC_LOGGING || STOIC_METRICS
import Stoic
import Synchronization

/// A clock the test moves by hand, for measuring a span without sleeping.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private let time = Mutex(Duration.zero)

    var now: Instant { Instant(offset: time.withLock { $0 }) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func advance(by duration: Duration) {
        time.withLock { $0 += duration }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw CancellationError()   // nothing here sleeps; a test that does is wrong
    }
}
#endif
