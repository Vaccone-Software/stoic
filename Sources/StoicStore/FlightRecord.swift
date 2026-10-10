public import Stoic

/// An event as a flight recorder kept it.
///
/// Values are stored as text. A private field's value is stored as
/// `<private>` unless the recorder was opened with `recordPrivateValues`.
public struct RecordedEvent: Sendable, Hashable, CustomStringConvertible {
    /// Increases by one per record across every run the file has seen.
    public let sequence: UInt64
    /// Wall-clock time, in nanoseconds since 1970.
    public let time: Int64
    public let level: Event.Level
    public let name: String
    public let label: String?
    public let fileID: String
    public let line: UInt
    public let fields: [Field]

    public struct Field: Sendable, Hashable, CustomStringConvertible {
        public let key: String
        public let value: String
        public let isPublic: Bool

        public var description: String { "\(key)=\(value)" }
    }

    public var description: String {
        var parts = ["\(level) \(name)"]
        if let label { parts.append("label=\(label)") }
        parts.append(contentsOf: fields.map(\.description))
        return parts.joined(separator: " ")
    }
}

/// What one run of the app left in its flight recorder.
public struct RecordedRun: Sendable {
    /// Its events, oldest first — as many as the file still holds.
    public let events: [RecordedEvent]
    /// Whether the run said it was exiting cleanly
    /// (``FlightRecorder/markCleanExit()``). `false` after a crash, a
    /// kill, a hang the watchdog ended, or a power loss.
    public let endedCleanly: Bool
    /// Whether the file still holds the run's start. `false` when the run
    /// recorded more than the file holds, so its oldest events are gone.
    public let isComplete: Bool
    /// When it started, in nanoseconds since 1970, if its start is held.
    public let startTime: Int64?
}

// MARK: Format

/// The on-disk layout.
///
///     header (32 bytes): "STOICFR1" | version u32 | capacity u32 | reserved
///     data (capacity bytes): records, each 8-byte aligned:
///         length u32 | crc32c u32 | sequence u64 | payload (length bytes)
///
/// The checksum covers sequence, length and payload, so a record torn by a
/// crash, or old bytes the writer has partly overwritten, never parse.
/// Records are found by scanning every aligned offset, which needs no index
/// that a crash could leave inconsistent with the data.
enum FlightFormat {
    static let magic: [UInt8] = Array("STOICFR1".utf8)
    static let version: UInt32 = 1
    static let headerSize = 32
    static let recordHeaderSize = 16
    static let alignment = 8
    static let maxString = 256
    static let maxFields = 32

    enum Kind: UInt8 {
        case event = 1
        case runStarted = 2
        case runEnded = 3
    }

    struct Record {
        let sequence: UInt64
        let offset: Int
        let size: Int
        let kind: Kind
        let event: RecordedEvent?
        let time: Int64
    }

    static func header(capacity: Int) -> [UInt8] {
        var bytes = magic
        bytes.appendLittleEndian(version)
        bytes.appendLittleEndian(UInt32(capacity))
        bytes.append(contentsOf: repeatElement(0, count: headerSize - bytes.count))
        return bytes
    }

    static func capacity(fromHeader bytes: [UInt8]) -> Int? {
        guard bytes.count >= headerSize, Array(bytes[0..<8]) == magic else { return nil }
        var reader = ByteReader(bytes, from: 8)
        guard reader.u32() == version, let capacity = reader.u32() else { return nil }
        return Int(capacity)
    }

    static func aligned(_ size: Int) -> Int {
        (size + alignment - 1) / alignment * alignment
    }

    /// A whole record, header and padding included.
    static func encode(sequence: UInt64, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(aligned(recordHeaderSize + payload.count))
        bytes.appendLittleEndian(UInt32(payload.count))
        bytes.appendLittleEndian(checksum(sequence: sequence, payload: payload))
        bytes.appendLittleEndian(sequence)
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: repeatElement(0, count: aligned(bytes.count) - bytes.count))
        return bytes
    }

    static func checksum(sequence: UInt64, payload: [UInt8]) -> UInt32 {
        var crc = CRC32C.Running()
        var prefix: [UInt8] = []
        prefix.appendLittleEndian(sequence)
        prefix.appendLittleEndian(UInt32(payload.count))
        crc.update(prefix)
        crc.update(payload)
        return crc.value
    }

    static func eventPayload(_ event: Event, time: Int64, recordPrivate: Bool) -> [UInt8] {
        var bytes: [UInt8] = [Kind.event.rawValue, UInt8(event.level.rawValue)]
        bytes.appendLittleEndian(UInt64(bitPattern: time))
        bytes.appendString(event.name.rawValue)
        bytes.appendOptionalString(event.label)
        bytes.appendString(event.fileID)
        bytes.appendLittleEndian(UInt32(truncatingIfNeeded: event.line))
        let fields = event.fields.prefix(maxFields)
        bytes.append(UInt8(fields.count))
        for field in fields {
            let isPublic = field.privacy == .public
            bytes.appendString(field.key)
            bytes.append(isPublic ? 1 : 0)
            let value: String
            switch field.value {
            case .error(let type, let description):
                // The type is public; the description can carry user data.
                value = isPublic || recordPrivate ? "\(type): \(description)" : "\(type): <private>"
            default:
                value = isPublic || recordPrivate ? field.value.description : "<private>"
            }
            bytes.appendString(value)
        }
        return bytes
    }

    static func markerPayload(_ kind: Kind, time: Int64) -> [UInt8] {
        var bytes: [UInt8] = [kind.rawValue]
        bytes.appendLittleEndian(UInt64(bitPattern: time))
        return bytes
    }

    /// Every intact record in `data`, in sequence order.
    static func scan(_ data: [UInt8]) -> [Record] {
        var records: [Record] = []
        var offset = 0
        while offset + recordHeaderSize <= data.count {
            if let record = parse(data, at: offset) {
                records.append(record)
                offset += record.size
            } else {
                offset += alignment
            }
        }
        return records.sorted { $0.sequence < $1.sequence }
    }

    private static func parse(_ data: [UInt8], at offset: Int) -> Record? {
        var reader = ByteReader(data, from: offset)
        guard let length = reader.u32(), let crc = reader.u32(), let sequence = reader.u64(),
              length > 0, Int(length) <= data.count - offset - recordHeaderSize
        else { return nil }
        let payload = Array(data[(offset + recordHeaderSize)..<(offset + recordHeaderSize + Int(length))])
        guard checksum(sequence: sequence, payload: payload) == crc else { return nil }
        let size = aligned(recordHeaderSize + Int(length))
        var body = ByteReader(payload, from: 0)
        guard let rawKind = body.u8(), let kind = Kind(rawValue: rawKind) else { return nil }
        switch kind {
        case .runStarted, .runEnded:
            guard let time = body.u64() else { return nil }
            return Record(sequence: sequence, offset: offset, size: size, kind: kind, event: nil, time: Int64(bitPattern: time))
        case .event:
            guard let rawLevel = body.u8(), let level = Event.Level(rawValue: Int(rawLevel)),
                  let time = body.u64(), let name = body.string(), let label = body.optionalString(),
                  let fileID = body.string(), let line = body.u32(), let count = body.u8()
            else { return nil }
            var fields: [RecordedEvent.Field] = []
            for _ in 0..<count {
                guard let key = body.string(), let flag = body.u8(), let value = body.string() else { return nil }
                fields.append(.init(key: key, value: value, isPublic: flag == 1))
            }
            let event = RecordedEvent(
                sequence: sequence, time: Int64(bitPattern: time), level: level, name: name,
                label: label, fileID: fileID, line: UInt(line), fields: fields
            )
            return Record(sequence: sequence, offset: offset, size: size, kind: kind, event: event, time: event.time)
        }
    }

    /// The most recent run in `records` (sequence order).
    static func lastRun(_ records: [Record]) -> RecordedRun? {
        guard !records.isEmpty else { return nil }
        let startIndex = records.lastIndex { $0.kind == .runStarted }
        let run = startIndex.map { Array(records[$0...]) } ?? records
        return RecordedRun(
            events: run.compactMap(\.event),
            endedCleanly: run.last?.kind == .runEnded,
            isComplete: startIndex != nil,
            startTime: startIndex.map { records[$0].time }
        )
    }
}

// MARK: Bytes

extension [UInt8] {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        for _ in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: value))
            value >>= 8
        }
    }

    /// A length-prefixed string, cut at `maxString` bytes on a character
    /// boundary so a long value cannot crowd out the rest of the record.
    mutating func appendString(_ string: String) {
        var utf8 = Array(string.utf8)
        if utf8.count > FlightFormat.maxString {
            var cut = FlightFormat.maxString
            // Back up past continuation bytes to the start of a scalar.
            while cut > 0, utf8[cut] & 0b1100_0000 == 0b1000_0000 { cut -= 1 }
            utf8 = Array(utf8[..<cut])
        }
        appendLittleEndian(UInt16(utf8.count))
        append(contentsOf: utf8)
    }

    mutating func appendOptionalString(_ string: String?) {
        if let string { appendString(string) } else { appendLittleEndian(UInt16.max) }
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var position: Int

    init(_ bytes: [UInt8], from position: Int) {
        self.bytes = bytes
        self.position = position
    }

    mutating func u8() -> UInt8? {
        guard position < bytes.count else { return nil }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func u16() -> UInt16? { integer() }
    mutating func u32() -> UInt32? { integer() }
    mutating func u64() -> UInt64? { integer() }

    private mutating func integer<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard position + size <= bytes.count else { return nil }
        var value: T = 0
        for index in (0..<size).reversed() {
            value = value << 8 | T(bytes[position + index])
        }
        position += size
        return value
    }

    mutating func string() -> String? {
        guard let length = u16(), length != .max, position + Int(length) <= bytes.count else { return nil }
        defer { position += Int(length) }
        return String(decoding: bytes[position..<(position + Int(length))], as: UTF8.self)
    }

    mutating func optionalString() -> String?? {
        let mark = position
        guard let length = u16() else { return nil }
        if length == .max { return .some(nil) }
        position = mark
        return string().map { .some($0) }
    }
}
