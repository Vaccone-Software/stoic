internal import Foundation
public import Stoic

/// What `JournaledLifecycleStore` writes: journal records and snapshots made
/// of length-prefixed JSON documents, so a document this build cannot decode
/// (a state a newer build added) is kept as its bytes, untouched, and
/// written back as it was.
///
/// Integers are little-endian. A *document* is `length:u32 | JSON`. Every
/// record starts `type:u8 | handedOff:u64 | seen:i128`: the journal sequence
/// up to which every commit's effects are in the outbox, and the latest
/// moment the store has seen, in attoseconds since 1970. Then, by type:
///
/// - `0x01` insert: `id | head` (documents);
/// - `0x02` commit: `id | head | entryCount:u32 | entry* | effectCount:u32 |
///   (keyLength:u8 | key | delivery)*`, each delivery a `LifecycleDelivery`
///   document, exactly the bytes handed to the outbox;
/// - `0x03` purge: `count:u32 | id*`;
/// - `0x04` mark: nothing more (the moment and hand-off mark at close).
///
/// A snapshot is `format:u8 (1) | handedOff:u64 | seen:i128 | count:u32 |
/// (id | head | entryCount:u32 | entry*)*`, every record in insertion order.
/// Heads are `LifecycleRecord`'s encoded form and entries
/// `LifecycleEntry`'s (design/27), with sorted keys.
enum LifecycleStoreFormat {
    enum Kind: UInt8 {
        case insert = 0x01
        case commit = 0x02
        case purge = 0x03
        case mark = 0x04
    }

    /// One effect of a commit, as handed to the outbox.
    struct Effect: Sendable {
        let key: IdempotencyKey
        let delivery: [UInt8]
    }

    /// A record as the journal holds it, its documents not yet decoded.
    struct Record {
        let kind: Kind
        let handedOff: UInt64
        let seen: Moment
        var documents: [[UInt8]] = []
        var entries: [[UInt8]] = []
        var effects: [Effect] = []
    }

    /// The store as a snapshot holds it.
    struct Snapshot {
        let handedOff: UInt64
        let seen: Moment
        var records: [(id: [UInt8], head: [UInt8], entries: [[UInt8]])] = []
    }

    // MARK: JSON

    static func encode(_ value: some Encodable, _ what: String) throws(StoreError) -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return Array(try encoder.encode(value))
        } catch {
            throw StoreError(kind: .invalidArgument, operation: "lifecycle", detail: "\(what) could not be encoded: \(error)")
        }
    }

    /// `bytes` decoded, or `nil` if they do not decode as `type`.
    static func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) -> T? {
        do {
            return try JSONDecoder().decode(type, from: Data(bytes))
        } catch {
            return nil
        }
    }

    // MARK: Writing

    static func header(_ kind: Kind, handedOff: UInt64, seen: Moment) -> [UInt8] {
        [kind.rawValue] + littleEndian(handedOff) + littleEndian(seen.sinceEpoch.attoseconds)
    }

    static func document(_ bytes: [UInt8]) -> [UInt8] {
        littleEndian(UInt32(bytes.count)) + bytes
    }

    static func insert(id: [UInt8], head: [UInt8], handedOff: UInt64, seen: Moment) -> [UInt8] {
        header(.insert, handedOff: handedOff, seen: seen) + document(id) + document(head)
    }

    static func commit(
        id: [UInt8], head: [UInt8], entries: [[UInt8]], effects: [Effect], handedOff: UInt64, seen: Moment
    ) -> [UInt8] {
        var bytes = header(.commit, handedOff: handedOff, seen: seen) + document(id) + document(head)
        bytes += littleEndian(UInt32(entries.count))
        for entry in entries { bytes += document(entry) }
        bytes += littleEndian(UInt32(effects.count))
        for effect in effects {
            // An effect key is 32 hexadecimal digits.
            let key = Array(effect.key.rawValue.utf8)
            bytes += [UInt8(key.count)] + key + document(effect.delivery)
        }
        return bytes
    }

    static func purge(ids: [[UInt8]], handedOff: UInt64, seen: Moment) -> [UInt8] {
        var bytes = header(.purge, handedOff: handedOff, seen: seen) + littleEndian(UInt32(ids.count))
        for id in ids { bytes += document(id) }
        return bytes
    }

    static func mark(handedOff: UInt64, seen: Moment) -> [UInt8] {
        header(.mark, handedOff: handedOff, seen: seen)
    }

    static func snapshot(_ snapshot: Snapshot) -> [UInt8] {
        var bytes: [UInt8] = [1] + littleEndian(snapshot.handedOff) + littleEndian(snapshot.seen.sinceEpoch.attoseconds)
        bytes += littleEndian(UInt32(snapshot.records.count))
        for record in snapshot.records {
            bytes += document(record.id) + document(record.head) + littleEndian(UInt32(record.entries.count))
            for entry in record.entries { bytes += document(entry) }
        }
        return bytes
    }

    // MARK: Reading

    /// Reads `bytes` front to back; any read past the end is corruption.
    struct Reader {
        let bytes: [UInt8]
        let path: String
        var offset = 0

        func corrupt(_ why: String) -> StoreError {
            StoreError(kind: .corrupt, operation: "lifecycle", path: path, detail: why)
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type, _ what: String) throws(StoreError) -> T {
            let size = T.bitWidth / 8
            guard bytes.count - offset >= size else { throw corrupt("\(what) is cut short") }
            defer { offset += size }
            return readLittleEndian(bytes, at: offset)
        }

        mutating func document(_ what: String) throws(StoreError) -> [UInt8] {
            let length = Int(try integer(UInt32.self, what))
            guard bytes.count - offset >= length else { throw corrupt("\(what) is cut short") }
            defer { offset += length }
            return Array(bytes[offset..<offset + length])
        }

        mutating func moment(_ what: String) throws(StoreError) -> Moment {
            Moment(sinceEpoch: Duration(attoseconds: try integer(Int128.self, what)))
        }

        func end() throws(StoreError) {
            guard offset == bytes.count else { throw corrupt("\(bytes.count - offset) bytes follow the end") }
        }
    }

    static func record(_ bytes: [UInt8], path: String) throws(StoreError) -> Record {
        var reader = Reader(bytes: bytes, path: path)
        let type = try reader.integer(UInt8.self, "the record type")
        guard let kind = Kind(rawValue: type) else { throw reader.corrupt("unknown record type \(type)") }
        var record = Record(
            kind: kind, handedOff: try reader.integer(UInt64.self, "the hand-off mark"), seen: try reader.moment("the moment"))
        switch kind {
        case .insert:
            record.documents = [try reader.document("an id"), try reader.document("a head")]
        case .commit:
            record.documents = [try reader.document("an id"), try reader.document("a head")]
            let entries = try reader.integer(UInt32.self, "the entry count")
            for _ in 0..<entries { record.entries.append(try reader.document("an entry")) }
            let effects = try reader.integer(UInt32.self, "the effect count")
            for _ in 0..<effects {
                let length = Int(try reader.integer(UInt8.self, "an effect key"))
                guard bytes.count - reader.offset >= length else { throw reader.corrupt("an effect key is cut short") }
                let key = String(decoding: bytes[reader.offset..<reader.offset + length], as: UTF8.self)
                reader.offset += length
                record.effects.append(Effect(key: IdempotencyKey(rawValue: key), delivery: try reader.document("an effect")))
            }
        case .purge:
            let count = try reader.integer(UInt32.self, "the id count")
            for _ in 0..<count { record.documents.append(try reader.document("an id")) }
        case .mark:
            break
        }
        try reader.end()
        return record
    }

    static func snapshot(_ bytes: [UInt8], path: String) throws(StoreError) -> Snapshot {
        var reader = Reader(bytes: bytes, path: path)
        let format = try reader.integer(UInt8.self, "the snapshot format")
        guard format == 1 else { throw reader.corrupt("snapshot format \(format) is not one this build reads") }
        var snapshot = Snapshot(
            handedOff: try reader.integer(UInt64.self, "the hand-off mark"), seen: try reader.moment("the moment"))
        let count = try reader.integer(UInt32.self, "the record count")
        for _ in 0..<count {
            let id = try reader.document("an id")
            let head = try reader.document("a head")
            let entryCount = try reader.integer(UInt32.self, "the entry count")
            var entries: [[UInt8]] = []
            for _ in 0..<entryCount { entries.append(try reader.document("an entry")) }
            snapshot.records.append((id, head, entries))
        }
        try reader.end()
        return snapshot
    }
}
