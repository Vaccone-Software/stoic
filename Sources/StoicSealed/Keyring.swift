#if STOIC_CRYPTO
public import Stoic
internal import Crypto
internal import Synchronization

/// Why a ``Keyring`` call failed.
///
/// ``custody(_:)`` carries what the custody said, and when that is
/// ``CustodyError/unavailable(_:)`` the keyring may well exist: **never answer
/// it by creating one.** ``missing`` is the only "there is no keyring", and it
/// is reported only when the custody answered that nothing is there.
public enum KeyringError: Error, Sendable, Hashable, CustomStringConvertible, Retryable {
    /// The custody failed or could not be reached.
    case custody(CustodyError)
    /// The custody holds no keyring under that name, and the caller asked
    /// not to create one (``Keyring/IfMissing/fail``), or it has been removed
    /// since this keyring was opened (``Keyring/reload()``).
    case missing
    /// The custody holds something under that name that is not a keyring: too
    /// short, the wrong magic, a checksum that does not match, no keys, a key
    /// listed twice. It is left exactly as it is, and never replaced by a
    /// new keyring, because it may be a keyring that was damaged.
    case corrupt
    /// A keyring written in a format this release does not read (a newer one).
    /// Left untouched.
    case unsupportedVersion(UInt8)
    /// The keyring has been destroyed (or found gone on reload): it seals
    /// nothing, because a key that is not in the custody could never be found
    /// again.
    case destroyed
    /// The current key cannot be retired: rotate first.
    case cannotRetireCurrent
    /// The custody reported success and then did not hold what was written: a
    /// write lost, or replaced by another writer. The new ring is not used.
    case notPersisted
    /// The ring is full: retire keys nothing sealed under them remains for.
    case tooManyKeys

    public var description: String {
        switch self {
        case .custody(let error): "keyring: \(error)"
        case .missing: "keyring: no keyring in the custody"
        case .corrupt: "keyring: the custody item is not a valid keyring (left untouched)"
        case .unsupportedVersion(let version): "keyring: format version \(version) is not supported (left untouched)"
        case .destroyed: "keyring: destroyed"
        case .cannotRetireCurrent: "keyring: the current key cannot be retired"
        case .notPersisted: "keyring: the custody did not hold what was written"
        case .tooManyKeys: "keyring: too many keys; retire the ones nothing is sealed under"
        }
    }

    public var retryDecision: RetryDecision {
        switch self {
        case .custody(let error): error.retryDecision
        case .missing, .corrupt, .unsupportedVersion, .destroyed, .cannotRetireCurrent, .notPersisted, .tooManyKeys: .stop
        }
    }
}

/// A named set of keys kept in one ``KeyCustody`` item: the key that seals now,
/// and the older keys still needed to open what was sealed before.
///
///     let opened = try Keyring.open(name: "app.keyring", custody: custody, ifMissing: .create)
///     let ring = opened.keyring                      // opened.created: first launch
///     let sealed = try Sealing.seal(data, context: "app.notes", key: ring.current)
///
/// - **Rotation** (``rotate()``) makes a new key current and *persists the ring
///   before returning it*: a key that sealed something is always in the custody.
///   Old keys stay, so older values still open.
/// - **Retirement** (``retire(id:)``) forgets a key. It is crypto-shredding: what
///   was sealed under it is unreadable from then on, to anyone, for ever.
///   Retire a key only when nothing sealed under it must still be read, and
///   know that a *backup* of the custody made earlier still holds it
///   (design/24).
/// - **Destruction** (``destroy()``) deletes the item: everything sealed under
///   the ring is gone.
///
/// ## Where a failure leaves it
///
/// Every change is one atomic ``KeyCustody/store(_:name:)`` of the whole ring,
/// made *before* the change is used and checked by reading it back. So the
/// custody item is, at every instant, a complete ring that holds every key
/// anything has been sealed under: before a rotation, the old ring; after it,
/// the old keys and the new. A crash or an error between is one or the other,
/// both readable. A ring a rotation persisted but never returned holds a key
/// that sealed nothing, which is harmless. A failure to store changes nothing
/// in memory either.
///
/// ## Opening
///
/// A custody that cannot be reached is an error, never "missing": opening with
/// ``IfMissing/create`` while the custody is unavailable throws and makes no
/// key. A custody item that is not a keyring is ``KeyringError/corrupt`` and is
/// not touched.
///
/// ## Threads and processes
///
/// Thread-safe. The custody is called under a lock that serialises changes,
/// never under the lock readers take, so a prompt that waits for the user does
/// not stall a seal on another thread. **Two processes sharing one keyring item
/// must not both create or rotate it**: the custody has no compare-and-swap,
/// so the writes would overwrite each other and could orphan data. Let one
/// process (the app) create and rotate; another (a command-line tool) opens with
/// ``IfMissing/fail`` and calls ``reload()`` to see a rotation. Reading the
/// ring back after a write catches the common interleaving, not all of them.
public final class Keyring: Sendable {
    /// What ``open(name:custody:ifMissing:)`` does when the custody holds no ring.
    public enum IfMissing: Sendable, Hashable {
        /// Make a keyring with one new key and store it.
        case create
        /// Throw ``KeyringError/missing``.
        case fail
    }

    /// A keyring and whether opening made it.
    public struct Opening: Sendable {
        public let keyring: Keyring
        /// `true` if the custody held none and this open created it: nothing
        /// sealed before can be opened, so this is the moment to start fresh
        /// (or to notice that data exists and the key is gone).
        public let created: Bool
    }

    /// The most keys one ring holds.
    public static let maximumKeys = 1024

    public let name: String
    private let custody: any KeyCustody

    private struct State {
        /// The keys, the current one first.
        var keys: [SealingKey]
        var destroyed = false
    }

    private let state: Mutex<State>
    /// Held for every change, and across the custody calls it makes.
    private let changes = Mutex<Void>(())

    private init(name: String, custody: any KeyCustody, keys: [SealingKey]) {
        self.name = name
        self.custody = custody
        self.state = Mutex(State(keys: keys))
    }

    // MARK: Opening

    /// The keyring stored under `name` in `custody`.
    ///
    /// - Throws: ``KeyringError``: ``KeyringError/custody(_:)`` if the custody
    ///   could not be asked (and then nothing is created, whatever `ifMissing`
    ///   says), ``KeyringError/missing`` if it holds none and `ifMissing` is
    ///   `.fail`, ``KeyringError/corrupt`` or
    ///   ``KeyringError/unsupportedVersion(_:)`` if it holds something that is not
    ///   a ring this release reads (left untouched).
    public static func open(name: String, custody: any KeyCustody, ifMissing: IfMissing) throws(KeyringError) -> Opening {
        let stored = try Self.load(name: name, custody: custody)
        if let stored {
            return Opening(keyring: Keyring(name: name, custody: custody, keys: try RingFormat.decode(stored)), created: false)
        }
        guard ifMissing == .create else { throw .missing }
        let ring = [SealingKey.generate()]
        try Self.persist(ring, name: name, custody: custody)
        SealedEvents.record(Event("sealed.keyring_created", level: .notice, fields: [.init("name", .string(name))]))
        return Opening(keyring: Keyring(name: name, custody: custody, keys: ring), created: true)
    }

    // MARK: Reading

    /// The key that seals now.
    ///
    /// - Throws: ``KeyringError/destroyed`` after ``destroy()``.
    public var current: SealingKey {
        get throws(KeyringError) {
            try state.withLock { (state) throws(KeyringError) -> SealingKey in
                guard !state.destroyed, let first = state.keys.first else { throw .destroyed }
                return first
            }
        }
    }

    /// The key named `id`, current or old; `nil` if the ring holds no such key
    /// (it was retired, or the ring was destroyed).
    public func key(id: KeyID) -> SealingKey? {
        state.withLock { state in state.destroyed ? nil : state.keys.first { $0.id == id } }
    }

    /// The identifiers of the keys held, the current one first.
    public var keyIDs: [KeyID] {
        state.withLock { state in state.destroyed ? [] : state.keys.map(\.id) }
    }

    // MARK: Changing

    /// Makes a new key current, persists the ring, and returns the key.
    ///
    /// The ring is stored, and read back, *before* anything is returned or
    /// published, so nothing is ever sealed under a key the custody does not
    /// hold. The old keys stay.
    ///
    /// - Throws: ``KeyringError``; nothing has changed (in memory, or as far as
    ///   this keyring knows in the custody) unless ``KeyringError/notPersisted``.
    @discardableResult
    public func rotate() throws(KeyringError) -> SealingKey {
        let rotated = try changes.withLock { (_) throws(KeyringError) -> SealingKey in
            let held = try live()
            guard held.count < Self.maximumKeys else { throw .tooManyKeys }
            var fresh = SealingKey.generate()
            while held.contains(where: { $0.id == fresh.id }) { fresh = SealingKey.generate() }
            let ring = [fresh] + held
            try Self.persist(ring, name: name, custody: custody)
            state.withLock { $0.keys = ring }
            return fresh
        }
        SealedEvents.record(Event("sealed.key_rotated", level: .notice, fields: [
            .init("name", .string(name)), .init("keys", .int(keyIDs.count)),
        ]))
        return rotated
    }

    /// Forgets the key `id`: crypto-shredding. What was sealed under it can no
    /// longer be opened, by this process or any other, once the ring is stored;
    /// a backup of the custody made earlier still holds it.
    ///
    /// - Returns: `false` if the ring held no such key (retiring twice is not
    ///   an error, so recovery can repeat it).
    /// - Throws: ``KeyringError/cannotRetireCurrent`` for the current key;
    ///   otherwise as ``rotate()``.
    @discardableResult
    public func retire(id: KeyID) throws(KeyringError) -> Bool {
        try retire(ids: [id]) > 0
    }

    /// Forgets every key in `ids`, in one stored ring: the same as retiring
    /// each, without a window in which only some are gone.
    ///
    /// - Returns: How many of them the ring held.
    @discardableResult
    public func retire(ids: [KeyID]) throws(KeyringError) -> Int {
        let wanted = Set(ids)
        let retired = try changes.withLock { (_) throws(KeyringError) -> Int in
            let held = try live()
            if let first = held.first, wanted.contains(first.id) { throw .cannotRetireCurrent }
            let ring = held.filter { !wanted.contains($0.id) }
            guard ring.count < held.count else { return 0 }
            try Self.persist(ring, name: name, custody: custody)
            state.withLock { $0.keys = ring }
            return held.count - ring.count
        }
        if retired > 0 {
            SealedEvents.record(Event("sealed.keys_retired", level: .notice, fields: [
                .init("name", .string(name)), .init("retired", .int(retired)),
            ]))
        }
        return retired
    }

    /// Deletes the keyring from the custody: everything sealed under any of its
    /// keys is lost for ever. After it, ``current`` throws and no key is found.
    ///
    /// - Throws: ``KeyringError/custody(_:)``; the keyring is then as it was.
    public func destroy() throws(KeyringError) {
        try changes.withLock { (_) throws(KeyringError) in
            do throws(CustodyError) {
                try custody.delete(name: name)
            } catch {
                throw .custody(error)
            }
            state.withLock { $0.keys = []; $0.destroyed = true }
        }
        SealedEvents.record(Event("sealed.keyring_destroyed", level: .notice, fields: [.init("name", .string(name))]))
    }

    /// Reads the custody again, for a process that shares the keyring with
    /// another: after the other rotated or retired, this sees its keys.
    ///
    /// - Throws: ``KeyringError/missing`` if the item has gone (and the keyring
    ///   is then destroyed here too), ``KeyringError/corrupt``,
    ///   ``KeyringError/unsupportedVersion(_:)`` or ``KeyringError/custody(_:)``,
    ///   each leaving what this keyring holds as it was.
    public func reload() throws(KeyringError) {
        try changes.withLock { (_) throws(KeyringError) in
            guard let stored = try Self.load(name: name, custody: custody) else {
                state.withLock { $0.keys = []; $0.destroyed = true }
                throw .missing
            }
            let keys = try RingFormat.decode(stored)
            state.withLock { $0.keys = keys; $0.destroyed = false }
        }
    }

    // MARK: Internals

    /// The keys held, or `.destroyed`.
    private func live() throws(KeyringError) -> [SealingKey] {
        try state.withLock { (state) throws(KeyringError) -> [SealingKey] in
            guard !state.destroyed else { throw .destroyed }
            return state.keys
        }
    }

    private static func load(name: String, custody: any KeyCustody) throws(KeyringError) -> [UInt8]? {
        do throws(CustodyError) {
            return try custody.load(name: name)
        } catch {
            throw .custody(error)
        }
    }

    /// Stores `ring` and reads it back: the ring is used only once the custody
    /// has been seen to hold it.
    private static func persist(_ ring: [SealingKey], name: String, custody: any KeyCustody) throws(KeyringError) {
        let bytes = RingFormat.encode(ring)
        do throws(CustodyError) {
            try custody.store(bytes, name: name)
        } catch {
            throw .custody(error)
        }
        guard try load(name: name, custody: custody) == bytes else { throw .notPersisted }
    }
}

extension Keyring: CustomStringConvertible, CustomReflectable {
    /// The name and how many keys, never a key.
    public var description: String { "Keyring(\(name), \(keyIDs.count) keys)" }

    /// Reflection shows the name and the number of keys: not the keys, and not
    /// the custody, which may hold the serialised ring (a test double does).
    public var customMirror: Mirror {
        Mirror(self, children: ["name": name, "keys": keyIDs.count], displayStyle: .class)
    }
}

/// The serialised form of a ring, which is what the custody holds.
///
///     offset  size  field
///          0     4  magic "SKR1"
///          4     1  format version (1)
///          5     2  number of keys n, at least 1, little-endian
///          7  48*n  the keys, the current one first: identifier (16), key (32)
///     7+48*n    16  checksum: the first 16 bytes of SHA-256 of everything before it
///
/// The checksum tells accidental damage from a ring; it is not a defence
/// against an attacker, who can write a ring of their own: the custody is the
/// trust boundary. Decoding refuses a ring with no keys, a key listed twice,
/// or any length but the one the count implies, and a version it does not
/// know is reported as such before the checksum is looked at.
enum RingFormat {
    static let magic: [UInt8] = Array("SKR1".utf8)
    static let version: UInt8 = 1
    static let headerSize = 7
    static let checksumSize = 16

    static func encode(_ keys: [SealingKey]) -> [UInt8] {
        var bytes = magic
        bytes.append(version)
        bytes.append(UInt8(truncatingIfNeeded: keys.count))
        bytes.append(UInt8(truncatingIfNeeded: keys.count >> 8))
        for key in keys { bytes.append(contentsOf: key.exportedForWrapping()) }
        bytes.append(contentsOf: checksum(of: bytes))
        return bytes
    }

    static func decode(_ bytes: [UInt8]) throws(KeyringError) -> [SealingKey] {
        guard bytes.starts(with: magic), bytes.count > magic.count else { throw .corrupt }
        guard bytes[4] == version else { throw .unsupportedVersion(bytes[4]) }
        guard bytes.count >= headerSize + checksumSize else { throw .corrupt }
        let count = Int(bytes[5]) | Int(bytes[6]) << 8
        guard count >= 1, bytes.count == headerSize + count * SealingKey.exportedByteCount + checksumSize else { throw .corrupt }
        let body = bytes.count - checksumSize
        guard Array(bytes[body...]) == checksum(of: bytes[..<body]) else { throw .corrupt }
        var keys: [SealingKey] = []
        var seen: Set<KeyID> = []
        for index in 0..<count {
            let start = headerSize + index * SealingKey.exportedByteCount
            guard let key = SealingKey(importing: Array(bytes[start..<start + SealingKey.exportedByteCount])),
                  seen.insert(key.id).inserted
            else { throw .corrupt }
            keys.append(key)
        }
        return keys
    }

    private static func checksum(of bytes: some Sequence<UInt8>) -> [UInt8] {
        Array(SHA256.hash(data: Array(bytes)).prefix(checksumSize))
    }
}
#endif
