public import Stoic

/// One side of a reconciliation, in memory, with faults a test scripts
/// (design/30).
///
///     let truth = SimulatedSide(["beach-clean": 12], label: "commitments")
///     let derived = SimulatedSide<String, Int>(label: "calendar")
///     await derived.inject(.readEmpty)                 // a broken query
///     let reconciler = Reconciler(SimulatedReconciliation(truth: truth, derived: derived))
///
/// Every applied write is kept, in order, and writes to one key that
/// overlapped are counted: a reconciler whose passes overlap is caught by
/// ``concurrentWrites``. A `slow` fault sleeps on the ambient clock, so a test
/// on a `TestClock` decides when it ends, and two writes can overlap.
public actor SimulatedSide<Key: Hashable & Comparable & Sendable, Value: Hashable & Sendable> {
    /// Names the side in its errors.
    public let label: String

    /// What the side holds now.
    public private(set) var entries: [Key: Value]

    /// Every applied write, in order: a value, or `nil` for a removal.
    public private(set) var writes: [(key: Key, value: Value?)] = []

    /// Every read, in order: its scope and what it returned (after faults).
    public private(set) var reads: [(scope: ReconcileScope<Key>, result: [Key: Value]?)] = []

    /// Writes to one key that began while another write to it was in flight.
    public private(set) var concurrentWrites = 0

    /// Calls made so far: reads and writes.
    public private(set) var calls = 0

    private var faults: [(fault: SideFault<Key>, remaining: Int)] = []
    private var inFlight: [Key: Int] = [:]
    private var interceptor: (@Sendable (SideCall<Key>) async -> Void)?

    public init(_ entries: [Key: Value] = [:], label: String) {
        self.entries = entries
        self.label = label
    }

    /// An outside writer: a value, or `nil` to remove the key. Not counted
    /// in ``writes``: it is the drift a reconciler must find.
    public func set(_ key: Key, _ value: Value?) {
        entries[key] = value
    }

    /// Scripts `fault` for the next `times` calls it applies to.
    public func inject(_ fault: SideFault<Key>, times: Int = 1) {
        guard times > 0 else { return }
        faults.append((fault, times))
    }

    /// Forgets every scripted fault not yet used: "the faults stop".
    public func clearFaults() {
        faults = []
    }

    /// Faults scripted and not yet used.
    public var scriptedFaults: Int {
        faults.reduce(0) { $0 + $1.remaining }
    }

    /// Called before every read and write, with what is about to happen:
    /// where a test cancels the task it is in, to play a crash at that point.
    public func intercept(_ interceptor: (@Sendable (SideCall<Key>) async -> Void)?) {
        self.interceptor = interceptor
    }

    /// Reads the side within `scope`, as a reconciliation's `desired` or
    /// `actual` does: complete, or thrown.
    public func read(_ scope: ReconcileScope<Key>) async throws -> [Key: Value] {
        calls += 1
        if let interceptor { await interceptor(.read(scope)) }
        try await slowIfScripted()
        try Task.checkCancellation()
        if take({ if case .failRead = $0 { true } else { false } }) {
            reads.append((scope, nil))
            throw SimulatedSideError(label: label, what: "the read failed")
        }
        let result: [Key: Value]
        if take({ if case .readEmpty = $0 { true } else { false } }) {
            result = [:]
        } else {
            switch scope {
            case .all: result = entries
            case .keys(let keys): result = entries.filter { keys.contains($0.key) }
            }
        }
        reads.append((scope, result))
        return result
    }

    /// Writes one key: a value, or `nil` to remove it. Already absent is
    /// success, so a removal is repeatable.
    public func write(_ key: Key, _ value: Value?) async throws {
        calls += 1
        if inFlight[key, default: 0] > 0 { concurrentWrites += 1 }
        inFlight[key, default: 0] += 1
        defer { inFlight[key, default: 1] -= 1 }
        if let interceptor { await interceptor(.write(key)) }
        try await slowIfScripted()
        try Task.checkCancellation()
        if take({ if case .failWrite(let target) = $0 { target == nil || target == key } else { false } }) {
            throw SimulatedSideError(label: label, what: "the write failed before applying")
        }
        if take({ if case .dropWrite(let target) = $0 { target == nil || target == key } else { false } }) {
            return
        }
        entries[key] = value
        writes.append((key, value))
        if take({ if case .applyThenFail(let target) = $0 { target == nil || target == key } else { false } }) {
            throw SimulatedSideError(label: label, what: "the write applied, then failed")
        }
    }

    private func slowIfScripted() async throws {
        var delay: Duration?
        if let index = faults.firstIndex(where: { if case .slow = $0.fault { true } else { false } }),
            case .slow(let duration) = faults[index].fault
        {
            delay = duration
            consume(index)
        }
        if let delay { try await Ambient.sleep(for: delay) }
    }

    /// Consumes one use of the first scripted fault `matches` accepts.
    private func take(_ matches: (SideFault<Key>) -> Bool) -> Bool {
        guard let index = faults.firstIndex(where: { matches($0.fault) }) else { return false }
        consume(index)
        return true
    }

    private func consume(_ index: Int) {
        faults[index].remaining -= 1
        if faults[index].remaining == 0 { faults.remove(at: index) }
    }
}

/// A fault a ``SimulatedSide`` plays on the next call it applies to.
public enum SideFault<Key: Hashable & Sendable>: Sendable, Hashable {
    /// The next read throws.
    case failRead
    /// The next read returns nothing: a broken query.
    case readEmpty
    /// The next write (to this key, or any) throws before applying.
    case failWrite(Key?)
    /// The next write (to this key, or any) applies, then throws: an unknown outcome.
    case applyThenFail(Key?)
    /// The next write (to this key, or any) is acknowledged and not applied.
    case dropWrite(Key?)
    /// The next call takes this long on the ambient clock.
    case slow(Duration)
}

/// What a ``SimulatedSide`` is about to do, as its interceptor sees it.
public enum SideCall<Key: Hashable & Sendable>: Sendable, Hashable {
    case read(ReconcileScope<Key>)
    case write(Key)
}

/// A scripted failure of a ``SimulatedSide``. Permanent, so a declared
/// operation does not retry it and a test's fault script is exactly what the
/// reconciler sees.
public struct SimulatedSideError: Error, Retryable, CustomStringConvertible {
    public let label: String
    public let what: String

    public init(label: String, what: String) {
        self.label = label
        self.what = what
    }

    public var retryDecision: RetryDecision { .stop }

    public var description: String { "\(label): \(what)" }
}

/// A reconciliation between two ``SimulatedSide``s holding one value type:
/// the truth's values are the derived side's wanted values, compared by `==`.
///
/// Its operations are on the remote backend `stoic.simulated` (capacity 16):
/// reads `.readOnly`, corrections `.idempotent` (a write of a whole value by
/// key, and a removal that is success when already absent).
public struct SimulatedReconciliation<Key: Hashable & Comparable & Sendable, Value: Hashable & Sendable>: Reconciliation {
    public typealias Failure = any Error

    public static var name: String { "stoic.simulated" }
    public static var readsTruth: Backend.Operation { backend.readOnly("truth.read") }
    public static var readsDerived: Backend.Operation { backend.readOnly("derived.read") }
    public static var corrects: Backend.Operation { backend.idempotent("derived.write") }
    private static var backend: Backend { .remote("stoic.simulated", capacity: 16) }

    public let truth: SimulatedSide<Key, Value>
    public let derived: SimulatedSide<Key, Value>

    public init(truth: SimulatedSide<Key, Value>, derived: SimulatedSide<Key, Value>) {
        self.truth = truth
        self.derived = derived
    }

    public func desired(_ scope: ReconcileScope<Key>, attempt: Attempt) async throws -> [Key: Value] {
        try await truth.read(scope)
    }

    public func actual(_ scope: ReconcileScope<Key>, attempt: Attempt) async throws -> [Key: Value] {
        try await derived.read(scope)
    }

    public func correct(_ correction: Correction<Key, Value, Value>, attempt: Attempt) async throws {
        switch correction {
        case .create(let key, let value), .update(let key, let value, was: _):
            try await derived.write(key, value)
        case .remove(let key, was: _):
            try await derived.write(key, nil)
        }
    }
}
