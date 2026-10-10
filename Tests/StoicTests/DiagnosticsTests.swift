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

    @Test func aSnapshotOfTheRingAgreesWithItselfWhileEventsArrive() async {
        let ring = EventRing(capacity: 64)
        let recording = Task {
            for index in 0..<4_000 {
                ring.record(Event("test.busy", fields: [.init("index", .int(index))]))
                if index % 64 == 0 { await Task.yield() }
            }
        }
        var snapshots = 0
        while !recording.isCancelled, ring.totalRecorded < 4_000 {
            let (events, total) = ring.consistentSnapshot()
            // A full ring holds exactly `capacity` events; until then, all of them.
            #expect(events.count == min(ring.capacity, total), "\(events.count) events retained of \(total) recorded")
            snapshots += 1
            await Task.yield()
        }
        await recording.value
        #expect(snapshots > 0)
    }
}
