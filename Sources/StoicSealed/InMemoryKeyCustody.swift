#if STOIC_CRYPTO
internal import Synchronization

/// A ``KeyCustody`` in memory, for tests: nothing persisted, and made to fail
/// on request so a test can see how its caller copes with a locked keychain, a
/// refusing one, or a write that never lands.
///
/// It behaves as the contract asks of a real one: `nil` only when absent,
/// `store` atomic and replacing, `delete` of nothing a success, an empty name
/// refused.
public final class InMemoryKeyCustody: KeyCustody {
    /// A call, for ``calls``.
    public enum Operation: Sendable, Hashable { case load, store, delete }

    /// One call made, failed ones included.
    public struct Call: Sendable, Hashable {
        public let operation: Operation
        public let name: String
    }

    /// What an injected fault does.
    public enum Fault: Sendable, Hashable {
        /// The call throws `error` and changes nothing.
        case fail(CustodyError)
        /// A `store` or `delete` reports success and changes nothing: a custody
        /// that loses a write. (On a `load` it does nothing.)
        case dropWrite
    }

    private struct State {
        var items: [String: [UInt8]]
        var faults: [(operation: Operation?, fault: Fault)] = []
        var calls: [Call] = []

        /// Counts the call, then takes the first fault queued for it, if any.
        mutating func begin(_ operation: Operation, _ name: String) throws(CustodyError) -> Fault? {
            calls.append(Call(operation: operation, name: name))
            guard let index = faults.firstIndex(where: { $0.operation == nil || $0.operation == operation }) else {
                guard !name.isEmpty else { throw .invalidName }
                return nil
            }
            let fault = faults.remove(at: index).fault
            if case .fail(let error) = fault { throw error }
            guard !name.isEmpty else { throw .invalidName }
            return fault
        }
    }

    private let state: Mutex<State>

    public init(_ items: [String: [UInt8]] = [:]) {
        state = Mutex(State(items: items))
    }

    /// The names held, sorted.
    public var names: [String] { state.withLock { $0.items.keys.sorted() } }

    /// The bytes under `name`, looked at without making a call: for a test to
    /// see what was persisted.
    public func contents(of name: String) -> [UInt8]? { state.withLock { $0.items[name] } }

    /// Puts bytes under `name` without making a call: a test setting the stage
    /// (a ring written by another process, a corrupt item).
    public func put(_ bytes: [UInt8], name: String) { state.withLock { $0.items[name] = bytes } }

    /// Every call made, in order.
    public var calls: [Call] { state.withLock { $0.calls } }

    /// Queues `fault` for the next call to `operation` (any call, if `nil`).
    /// Several queue, each used once, in order.
    public func inject(_ fault: Fault, on operation: Operation? = nil) {
        state.withLock { $0.faults.append((operation, fault)) }
    }

    /// Makes the next call, or the next `operation`, throw `error`.
    public func failNext(with error: CustodyError, on operation: Operation? = nil) {
        inject(.fail(error), on: operation)
    }

    public func load(name: String) throws(CustodyError) -> [UInt8]? {
        try state.withLock { state throws(CustodyError) in
            _ = try state.begin(.load, name)
            return state.items[name]
        }
    }

    public func store(_ bytes: [UInt8], name: String) throws(CustodyError) {
        try state.withLock { state throws(CustodyError) in
            if try state.begin(.store, name) == .dropWrite { return }
            state.items[name] = bytes
        }
    }

    public func delete(name: String) throws(CustodyError) {
        try state.withLock { state throws(CustodyError) in
            if try state.begin(.delete, name) == .dropWrite { return }
            state.items[name] = nil
        }
    }
}
#endif
