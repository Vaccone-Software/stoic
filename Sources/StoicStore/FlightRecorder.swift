public import Stoic
internal import Synchronization

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#endif

/// Keeps the app's recent events in a file that survives the app, so the
/// next launch can say what it was doing when it died.
///
///     let recorder = try FlightRecorder(path: supportDirectory + "/flight.rec")
///     if let last = recorder.previousRun, !last.endedCleanly {
///         report("previous run ended abruptly", last.events.suffix(50))
///     }
///     try await withAmbient({ $0.instrumentation = CompositeInstrumentation([recorder, OSLogInstrumentation()]) }) {
///         try await app.run()
///     }
///     recorder.markCleanExit()
///
/// A crash report says where the app died. It does not say what the app was
/// deciding: that the sync engine had just retried twice, a circuit opened,
/// a state machine timed out. This does — the events Stoic's primitives
/// already emit, written as they happen to a fixed-size file on the device.
///
/// **Survives what it must.** Each event is one `pwrite` into the kernel's
/// page cache, which outlives the process, so a crash, a kill or a watchdog
/// termination loses nothing written. A power loss can lose what was not yet
/// flushed; call ``flush()`` before something risky to make everything so
/// far durable. A record cut short by any of these is recognised by its
/// checksum and skipped, never misread.
///
/// **Never the cause of a crash.** Memory-mapping the file would save the
/// system call, but writing to a mapped page the disk cannot back — a full
/// disk, a copy-on-write block under a snapshot — kills the process with
/// SIGBUS. A write returns an error instead: the recorder stops, says so in
/// ``status``, and the app goes on.
///
/// **Bounded and private.** The file never grows past `capacity`; the
/// oldest events are overwritten first. Private field values are stored as
/// `<private>` unless `recordPrivateValues` is set: the file may end up in
/// a diagnostics bundle that leaves the device.
public final class FlightRecorder: Instrumentation {
    /// Whether the recorder is still writing.
    public enum Status: Sendable {
        case recording
        /// A write failed; nothing more is recorded.
        case stopped(StoreError)
    }

    /// What the previous run of the app recorded, read when this one opened
    /// the file. `nil` if the file is new, or unreadable and started over.
    public let previousRun: RecordedRun?

    /// The least severe level recorded.
    public let minimumLevel: Event.Level

    private struct Writer {
        var file: OpenFile?
        var head: Int
        var nextSequence: UInt64
        var status: Status = .recording
    }

    private let fileSystem: any FileSystem
    private let path: String
    private let capacity: Int
    private let recordPrivateValues: Bool
    private let wallClock: @Sendable () -> Int64
    private let writer: Mutex<Writer>

    /// Opens the recording at `path`, creating it if needed, and reads what
    /// the previous run left in it.
    ///
    /// - Parameters:
    ///   - path: The file. Keep it somewhere that is not backed up or synced.
    ///   - capacity: Bytes of events kept; the file is this plus a 32-byte
    ///     header, allocated up front. A megabyte holds several thousand
    ///     typical events.
    ///   - minimumLevel: The least severe level recorded.
    ///   - recordPrivateValues: Store private field values as they are.
    ///   - fileSystem: Where the file lives; a simulated one in tests.
    /// - Throws: ``StoreError`` if the file cannot be opened or allocated.
    ///   An existing file that is unreadable is not an error: it is started
    ///   over, and ``previousRun`` is `nil`.
    public convenience init(
        path: String,
        capacity: Int = 1 << 20,
        minimumLevel: Event.Level = .info,
        recordPrivateValues: Bool = false,
        fileSystem: any FileSystem = PosixFileSystem()
    ) throws(StoreError) {
        try self.init(
            path: path, capacity: capacity, minimumLevel: minimumLevel,
            recordPrivateValues: recordPrivateValues, fileSystem: fileSystem, wallClock: WallClock.now
        )
    }

    init(
        path: String,
        capacity: Int,
        minimumLevel: Event.Level,
        recordPrivateValues: Bool,
        fileSystem: any FileSystem,
        wallClock: @escaping @Sendable () -> Int64
    ) throws(StoreError) {
        precondition(capacity >= 4096 && capacity <= Int(UInt32.max), "FlightRecorder capacity must be between 4 KiB and 4 GiB")
        precondition(capacity % FlightFormat.alignment == 0, "FlightRecorder capacity must be a multiple of 8")
        self.fileSystem = fileSystem
        self.path = path
        self.capacity = capacity
        self.minimumLevel = minimumLevel
        self.recordPrivateValues = recordPrivateValues
        self.wallClock = wallClock

        let file = try fileSystem.open(path, mode: .readWriteCreate)
        let records: [FlightFormat.Record]
        do {
            records = try Self.readOrReset(file, capacity: capacity, fileSystem: fileSystem)
        } catch {
            // stoic:allow(discarded-try): the open failed already; that error is the one to report
            try? fileSystem.close(file)
            throw error
        }
        previousRun = FlightFormat.lastRun(records)
        let last = records.last
        let head = last.map { $0.offset + $0.size } ?? 0
        writer = Mutex(Writer(file: file, head: head >= capacity ? 0 : head, nextSequence: (last?.sequence ?? 0) + 1))
        append(FlightFormat.markerPayload(.runStarted, time: wallClock()))
    }

    deinit {
        if let file = writer.withLock({ $0.file }) {
            // stoic:allow(discarded-try): nothing can be done about a failed close while deallocating
            try? fileSystem.close(file)
        }
    }

    /// Whether the recorder is still writing.
    public var status: Status {
        writer.withLock { $0.status }
    }

    public func isEnabled(_ level: Event.Level) -> Bool {
        level >= minimumLevel
    }

    public func record(_ event: Event) {
        guard event.level >= minimumLevel else { return }
        append(FlightFormat.eventPayload(event, time: wallClock(), recordPrivate: recordPrivateValues))
    }

    /// Records that this run is ending on purpose, so the next one sees
    /// ``RecordedRun/endedCleanly``. Call it last, from the app's
    /// termination path, after the services have stopped.
    public func markCleanExit() {
        append(FlightFormat.markerPayload(.runEnded, time: wallClock()))
        flush()
    }

    /// Makes everything recorded so far durable against power loss, too.
    /// One full sync: call it at moments that matter, not per event.
    public func flush() {
        writer.withLock { writer in
            guard case .recording = writer.status, let file = writer.file else { return }
            do throws(StoreError) {
                try fileSystem.fullSync(file)
            } catch {
                writer.status = .stopped(error)
            }
        }
    }

    /// Everything this run has recorded that the file still holds, oldest
    /// first. Reads the file.
    public func currentRun() throws(StoreError) -> RecordedRun {
        let file = try fileSystem.open(path, mode: .read)
        defer {
            // stoic:allow(discarded-try): a read-only descriptor; its close cannot lose data
            try? fileSystem.close(file)
        }
        let data = try fileSystem.read(file, at: FlightFormat.headerSize, count: capacity)
        return FlightFormat.lastRun(FlightFormat.scan(data))
            ?? RecordedRun(events: [], endedCleanly: false, isComplete: false, startTime: nil)
    }

    // MARK: Writing

    private func append(_ payload: [UInt8]) {
        writer.withLock { writer in
            guard case .recording = writer.status, let file = writer.file else { return }
            let record = FlightFormat.encode(sequence: writer.nextSequence, payload: payload)
            guard record.count <= capacity / 4 else { return }
            if writer.head + record.count > capacity { writer.head = 0 }
            do throws(StoreError) {
                try fileSystem.write(file, record, at: FlightFormat.headerSize + writer.head)
                writer.head += record.count
                writer.nextSequence += 1
            } catch {
                writer.status = .stopped(error)
            }
        }
    }

    // MARK: Opening

    private static func readOrReset(_ file: OpenFile, capacity: Int, fileSystem: any FileSystem) throws(StoreError) -> [FlightFormat.Record] {
        let total = FlightFormat.headerSize + capacity
        if try fileSystem.size(of: file) == total {
            let header = try fileSystem.read(file, at: 0, count: FlightFormat.headerSize)
            if FlightFormat.capacity(fromHeader: header) == capacity {
                return FlightFormat.scan(try fileSystem.read(file, at: FlightFormat.headerSize, count: capacity))
            }
        }
        // New, resized or unreadable: start over. The data region is written
        // out in full so its blocks are allocated now, and a full disk is an
        // error here rather than a failed write later.
        try fileSystem.truncate(file, to: 0)
        try fileSystem.write(file, FlightFormat.header(capacity: capacity), at: 0)
        let chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var offset = 0
        while offset < capacity {
            let count = min(chunk.count, capacity - offset)
            try fileSystem.write(file, count == chunk.count ? chunk : Array(chunk[..<count]), at: FlightFormat.headerSize + offset)
            offset += count
        }
        try fileSystem.fullSync(file)
        return []
    }
}

/// Wall-clock time, without Foundation.
enum WallClock {
    @Sendable static func now() -> Int64 {
        var spec = timespec()
        // clock_gettime fills the struct whose address it is given; it lives for the call.
        _ = unsafe clock_gettime(CLOCK_REALTIME, &spec)
        return Int64(spec.tv_sec) * 1_000_000_000 + Int64(spec.tv_nsec)
    }
}
