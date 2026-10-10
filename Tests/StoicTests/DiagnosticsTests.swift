@testable import Stoic
import StoicTesting
import Testing

@Suite("Diagnostics", .serialized)
struct DiagnosticsTests {
    @Test func theRingKeepsTheNewestEventsInOrder() {
        let ring = EventRing(capacity: 3)
        for index in 0..<5 { ring.record(Event(EventName(rawValue: "test.e\(index)"))) }
        #expect(ring.events.map(\.name.rawValue) == ["test.e2", "test.e3", "test.e4"])
        #expect(ring.totalRecorded == 5)
    }

    @Test func theSnapshotRedactsPrivateFieldsByDefault() async throws {
        let ring = Diagnostics.install(capacity: 16)
        ring.record(Event("retry.exhausted", level: .notice, label: "sync", fields: [
            .init("attempt", .int(3)),
            .init("error", .string("token=hunter2")),
        ]))
        let report = Diagnostics.snapshot()
        #expect(report.contains("retry.exhausted"))
        #expect(report.contains("attempt=3"))
        #expect(!report.contains("hunter2"))
        #expect(Diagnostics.snapshot(includePrivate: true).contains("hunter2"))
    }
}
