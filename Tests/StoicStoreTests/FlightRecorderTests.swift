#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Stoic
@testable import StoicStore
import Synchronization
import Testing

@Suite("Flight recorder")
struct FlightRecorderTests {
    static let path = "/d/flight.rec"

    /// A wall clock that ticks one second per reading, so times are exact.
    static func ticking() -> @Sendable () -> Int64 {
        let now = Atomic<Int64>(0)
        return { now.wrappingAdd(1_000_000_000, ordering: .relaxed).newValue }
    }

    static func open(
        _ disk: SimulatedFileSystem,
        capacity: Int = 64 * 1024,
        recordPrivateValues: Bool = false
    ) throws(StoreError) -> FlightRecorder {
        try FlightRecorder(
            path: path, capacity: capacity, minimumLevel: .info, recordPrivateValues: recordPrivateValues,
            fileSystem: disk, wallClock: ticking()
        )
    }

    static func disk() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        return disk
    }

    static func event(_ number: Int, level: Event.Level = .info) -> Event {
        Event(EventName(rawValue: "test.e\(number)"), level: level, label: "worker", fields: [.init("n", .int(number))])
    }

    @Test func theNextLaunchReadsWhatThePreviousRunRecorded() throws {
        let disk = try Self.disk()
        do {
            let recorder = try Self.open(disk)
            #expect(recorder.previousRun == nil)
            recorder.record(Self.event(1))
            recorder.record(Self.event(2, level: .debug))   // below the minimum: not kept
            recorder.record(Self.event(3, level: .error))
        }
        let next = try Self.open(disk)
        let run = try #require(next.previousRun)
        #expect(run.events.map(\.name) == ["test.e1", "test.e3"])
        #expect(run.events.map(\.level) == [.info, .error])
        #expect(run.events.first?.label == "worker")
        #expect(run.events.first?.fields == [.init(key: "n", value: "1", isPublic: true)])
        #expect(run.isComplete)
        #expect(!run.endedCleanly, "no clean exit was marked: a crash, as far as anyone can tell")
    }

    @Test func aCleanExitIsRecognised() throws {
        let disk = try Self.disk()
        do {
            let recorder = try Self.open(disk)
            recorder.record(Self.event(1))
            recorder.markCleanExit()
        }
        #expect(try Self.open(disk).previousRun?.endedCleanly == true)
    }

    @Test func eachLaunchSeesOnlyTheRunBeforeIt() throws {
        let disk = try Self.disk()
        do {
            let first = try Self.open(disk)
            first.record(Self.event(1))
        }
        do {
            let second = try Self.open(disk)
            #expect(second.previousRun?.events.map(\.name) == ["test.e1"])
            second.record(Self.event(2))
            second.record(Self.event(3))
        }
        let third = try Self.open(disk)
        let run = try #require(third.previousRun)
        #expect(run.events.map(\.name) == ["test.e2", "test.e3"])
        let sequences = run.events.map(\.sequence)
        #expect(sequences == sequences.sorted() && sequences.first! > 1, "sequences continue across runs")
    }

    @Test func privateValuesAreRedactedUnlessAskedFor() throws {
        struct Leak: Error, CustomStringConvertible { var description: String { "token hunter2" } }
        let event = Event("test.private", level: .warning, fields: [
            .init("user", .string("alice")),
            .init("route", .string("/sync"), privacy: .public),
            .init("error", .error(Leak())),
        ])
        for recordPrivate in [false, true] {
            let disk = try Self.disk()
            do {
                let recorder = try Self.open(disk, recordPrivateValues: recordPrivate)
                recorder.record(event)
            }
            let fields = try #require(try Self.open(disk).previousRun?.events.first?.fields)
            let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
            #expect(values["route"] == "/sync")
            if recordPrivate {
                #expect(values["user"] == "alice")
                #expect(values["error"]?.hasSuffix("token hunter2") == true)
            } else {
                #expect(values["user"] == "<private>")
                #expect(values["error"]?.hasSuffix(": <private>") == true)
                #expect(values["error"]?.contains("Leak") == true, "the error's type is public")
            }
        }
    }

    @Test func theOldestEventsGiveWayAndTheNewestSurvive() throws {
        let disk = try Self.disk()
        do {
            let recorder = try Self.open(disk, capacity: 4096)
            for number in 1...500 { recorder.record(Self.event(number)) }
        }
        let run = try #require(try Self.open(disk, capacity: 4096).previousRun)
        #expect(!run.isComplete, "the run's start has been overwritten")
        #expect(run.events.last?.name == "test.e500")
        let numbers = run.events.compactMap { Int($0.name.dropFirst("test.e".count)) }
        #expect(numbers == Array((numbers.first ?? 0)...500), "a contiguous run of the newest events")
        #expect(numbers.count > 20)
    }

    @Test func aFileThatIsNotARecordingIsStartedOver() throws {
        let disk = try Self.disk()
        let file = try disk.open(Self.path, mode: .readWriteCreate)
        try disk.write(file, Array("not a flight recording".utf8), at: 0)
        try disk.close(file)
        let recorder = try Self.open(disk)
        #expect(recorder.previousRun == nil)
        recorder.record(Self.event(1))
        #expect(try Self.open(disk).previousRun?.events.map(\.name) == ["test.e1"])
    }

    @Test func garbageInsideTheRecordingIsNeverMisread() throws {
        let disk = try Self.disk()
        do {
            let recorder = try Self.open(disk, capacity: 8192)
            for number in 1...20 { recorder.record(Self.event(number)) }
        }
        // Scribble over the middle of the data: some records lose bytes.
        let file = try disk.open(Self.path, mode: .readWrite)
        var random = SimulatedFileSystem.SplitMix(seed: 7)
        try disk.write(file, (0..<700).map { _ in UInt8(truncatingIfNeeded: random.next()) }, at: 32 + 600)
        try disk.close(file)
        let events = try #require(try Self.open(disk, capacity: 8192).previousRun).events
        #expect(events.count < 20)
        for event in events {
            let number = Int(event.name.dropFirst("test.e".count))
            #expect(event.fields == [.init(key: "n", value: number.map(String.init) ?? "?", isPublic: true)])
        }
    }

    @Test func longValuesAreCutOnACharacterBoundary() throws {
        let disk = try Self.disk()
        let long = String(repeating: "é", count: 200) + "🙂"   // 2-byte scalars: the cut falls mid-scalar
        do {
            let recorder = try Self.open(disk, recordPrivateValues: true)
            recorder.record(Event("test.long", fields: [.init("text", .string(long))]))
        }
        let value = try #require(try Self.open(disk).previousRun?.events.first?.fields.first?.value)
        #expect(value.utf8.count <= 256)
        #expect(long.hasPrefix(value))
    }

    @Test func aFailedWriteStopsTheRecorderAndNothingElse() throws {
        let disk = try Self.disk()
        let recorder = try Self.open(disk)
        disk.inject(ENOSPC, on: .write)
        recorder.record(Self.event(1))
        guard case .stopped(let error) = recorder.status else {
            Issue.record("expected the recorder to stop")
            return
        }
        #expect(error.kind == .diskFull)
        recorder.record(Self.event(2))   // ignored, and does not trap
    }

    @Test func aProcessCrashLosesNothingWritten() throws {
        // A process crash keeps the page cache: every completed write is
        // there for the next launch, synced or not.
        let disk = try Self.disk()
        let recorder = try Self.open(disk)
        for number in 1...50 { recorder.record(Self.event(number)) }
        let next = try Self.open(disk)   // the old recorder never closed: it "crashed"
        #expect(next.previousRun?.events.count == 50)
        _ = recorder
    }

    @Test func atEveryCrashPointRecoveryReadsOnlyWhatWasWrittenAndKeepsWhatWasFlushed() async throws {
        let report = try await exploreCrashes(
            "flight recorder",
            samples: 8,
            setup: { disk in
                try disk.createDirectory("/d")
                _ = try Self.open(disk, capacity: 4096)
            },
            operation: { disk in
                let recorder = try Self.open(disk, capacity: 4096)
                for number in 1...12 {
                    recorder.record(Self.event(number))
                    if number == 8 {
                        recorder.flush()
                        disk.checkpoint("flushed")
                    }
                }
            },
            check: { disk, context in
                let recorder = try Self.open(disk, capacity: 4096)
                let numbers = (recorder.previousRun?.events ?? []).map { event -> Int? in
                    guard let number = Int(event.name.dropFirst("test.e".count)),
                          event.fields == [.init(key: "n", value: String(number), isPublic: true)]
                    else { return nil }
                    return number
                }
                if numbers.contains(nil) { return "a record was misread: \(numbers)" }
                let recovered = numbers.compactMap(\.self)
                if recovered != recovered.sorted() { return "out of order: \(recovered)" }
                if context.reached("flushed"), !(1...8).allSatisfy(recovered.contains) {
                    return "flushed events lost: recovered \(recovered)"
                }
                return nil
            }
        )
        #expect(report.violations.isEmpty, "\(report)\n\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.images > 50)
    }

    @Test func aRealFileOnDisk() throws {
        let directory = try TempDirectory()
        let path = directory.file("flight.rec")
        do {
            let recorder = try FlightRecorder(path: path, capacity: 16 * 1024)
            recorder.record(Self.event(1))
            recorder.markCleanExit()
        }
        let run = try #require(try FlightRecorder(path: path, capacity: 16 * 1024).previousRun)
        #expect(run.events.map(\.name) == ["test.e1"])
        #expect(run.endedCleanly)
        #expect((run.startTime ?? 0) > 1_700_000_000 * 1_000_000_000, "a real wall-clock time")
    }
}
