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
