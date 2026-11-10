#if STOIC_ATTESTATION
public import Stoic

/// Where a server keeps App Attest keys and spent enrolment challenges: the
/// app's database (design/29). ``AppAttestGate`` is its one client.
///
/// What a conforming ledger promises: `insert` never overwrites a key id
/// already held; `commit` writes a record only if the stored revision is
/// still `revision` (compare-and-set), in one step; `spend` records a
/// challenge id until `expiry` and returns `false` if it is already
/// recorded. Errors are the ledger's own; the gate answers them as
/// unavailable (a 503), never as a refusal.
public protocol AppAttestLedger: Sendable {
    /// The record of key `id`, or `nil`.
    func key(_ id: [UInt8]) async throws -> AppAttestKeyRecord?
    /// Keeps `record`, unless its key id is held: then nothing is written and it returns `false`.
    func insert(_ record: AppAttestKeyRecord) async throws -> Bool
    /// Replaces the record of `record`'s key if its stored revision is `revision`; `false` otherwise.
    func commit(_ record: AppAttestKeyRecord, over revision: UInt64) async throws -> Bool
    /// Forgets key `id`.
    func remove(_ id: [UInt8]) async throws
    /// Records challenge `id` as spent until `expiry`; `false` if it already was.
    func spend(challenge id: [UInt8], until expiry: Moment) async throws -> Bool
}

/// A ledger in memory, for tests and a single process: nothing survives it.
///
/// Spent challenges are kept until their expiry passes by the time of the
/// next `spend`, so the set stays as small as the challenges in flight.
public actor InMemoryAppAttestLedger: AppAttestLedger {
    private var keys: [[UInt8]: AppAttestKeyRecord] = [:]
    private var spent: [[UInt8]: Moment] = [:]
    private var conflicts = 0

    public init() {}

    /// The records held, for a test to look at.
    public var records: [AppAttestKeyRecord] { Array(keys.values) }

    /// Makes the next `count` commits find another revision, as a second
    /// server committing first would.
    public func conflictNextCommits(_ count: Int) {
        conflicts += count
    }

    public func key(_ id: [UInt8]) -> AppAttestKeyRecord? {
        keys[id]
    }

    public func insert(_ record: AppAttestKeyRecord) -> Bool {
        guard keys[record.key.id] == nil else { return false }
        keys[record.key.id] = record
        return true
    }

    public func commit(_ record: AppAttestKeyRecord, over revision: UInt64) -> Bool {
        if conflicts > 0 {
            conflicts -= 1
            return false
        }
        guard let stored = keys[record.key.id], stored.revision == revision else { return false }
        keys[record.key.id] = record
        return true
    }

    public func remove(_ id: [UInt8]) {
        keys[id] = nil
    }

    public func spend(challenge id: [UInt8], until expiry: Moment) -> Bool {
        let now = Moment.now
        spent = spent.filter { $0.value >= now }
        guard spent[id] == nil else { return false }
        spent[id] = expiry
        return true
    }
}
#endif
