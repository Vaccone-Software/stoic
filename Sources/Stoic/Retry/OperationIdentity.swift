internal import Synchronization

/// One operation: a `retry`, a `hedge`, or one run of `recur`. Every attempt
/// at it shares it, and with it the operation's idempotency key, drawn the
/// first time an attempt asks.
///
/// **Operations inside operations.** An operation started while an attempt
/// of another is running — a library's `retry` called from an app's `retry`,
/// a `hedge` inside a `retry` — is a *sub-operation* of it. Its key is not
/// drawn afresh: it is derived from the enclosing operation's key, its own
/// call site and its ordinal there, so it is the same on every attempt of the
/// enclosing operation. That is the point. When the inner retry collapses to
/// one attempt (`retry.nested`), the retrying really happens at the outer
/// layer, and a key drawn per inner `retry` call would be new on every outer
/// attempt: the double charge the key exists to prevent.
///
/// **The ordinal.** Two sub-operations from the same line in one attempt (a
/// loop) are different operations and need different keys, so each gets the
/// count of sub-operations that line had already started in that attempt:
/// the n-th call from a line gets the same key on every attempt that reaches
/// it the same way. Sub-operations on different lines never shift each
/// other's ordinals. Two cases do not reach it the same way, and need a key
/// from the data instead (`IdempotencyKey(rawValue: item.id)`): a loop whose
/// items change between attempts, where the n-th call means a different
/// item; and sub-operations started concurrently from one line, which take
/// their ordinals in the order they start.
///
/// Attempts of a hedge run at once and each counts its own ordinals, so a
/// sub-operation reached the same way by two hedged copies has one key: the
/// copies are the same operation.
final class OperationIdentity: Sendable {
    private struct Parent: Sendable {
        let identity: OperationIdentity
        let ordinal: Int
    }

    /// A line of code in one attempt, for counting the sub-operations it starts.
    private struct Site: Hashable, Sendable {
        let attempt: Int
        let fileID: String
        let line: UInt
    }

    private struct State: Sendable {
        var key: IdempotencyKey?
        // Bit `n % 64` is set while attempt `n` runs. A retry runs one attempt
        // at a time, a hedge a few at once; a collision can only make a task
        // an attempt left running look nested for a while, never the reverse.
        var live: UInt64 = 0
        var ordinals: [Site: Int] = [:]
    }

    private let fileID: String
    private let line: UInt
    private let parent: Parent?
    private let state = Mutex(State())

    /// A top-level operation, whose key is drawn from the ambient random
    /// source at this call site when first asked for.
    init(fileID: String, line: UInt) {
        self.fileID = fileID
        self.line = line
        self.parent = nil
    }

    private init(fileID: String, line: UInt, parent: Parent) {
        self.fileID = fileID
        self.line = line
        self.parent = parent
    }

    /// The operation starting here: a sub-operation of the attempt running
    /// in the current task, if there is one, else a top-level operation.
    static func starting(fileID: String, line: UInt) -> OperationIdentity {
        guard let context = RetryContext.active, context.operation.isLive(attempt: context.attempt) else {
            return OperationIdentity(fileID: fileID, line: line)
        }
        let ordinal = context.operation.nextOrdinal(attempt: context.attempt, fileID: fileID, line: line)
        return OperationIdentity(fileID: fileID, line: line, parent: Parent(identity: context.operation, ordinal: ordinal))
    }

    /// Whether this operation started inside another's attempt.
    var isSubOperation: Bool { parent != nil }

    var idempotencyKey: IdempotencyKey {
        // Lock order: a sub-operation's lock, then its parent's; a parent
        // never takes a child's.
        state.withLock { state in
            if let key = state.key { return key }
            let drawn: IdempotencyKey
            if let parent {
                drawn = .derived(from: parent.identity.idempotencyKey, fileID: fileID, line: line, ordinal: parent.ordinal)
            } else {
                drawn = .random(fileID: fileID, line: line)
            }
            state.key = drawn
            return drawn
        }
    }

    /// Runs `body` as attempt `number`: operations it starts are
    /// sub-operations of this one, and a `retry` it starts is nested.
    nonisolated(nonsending) func running<R>(attempt number: Int, _ body: nonisolated(nonsending) () async -> R) async -> R {
        begin(attempt: number)
        defer { end(attempt: number) }
        return await RetryContext.$active.withValue(RetryContext(operation: self, attempt: number)) {
            await body()
        }
    }

    func begin(attempt number: Int) {
        state.withLock { $0.live |= Self.bit(number) }
    }

    func end(attempt number: Int) {
        state.withLock { state in
            state.live &= ~Self.bit(number)
            if !state.ordinals.isEmpty {
                state.ordinals = state.ordinals.filter { $0.key.attempt != number }
            }
        }
    }

    func isLive(attempt number: Int) -> Bool {
        state.withLock { $0.live & Self.bit(number) != 0 }
    }

    private func nextOrdinal(attempt: Int, fileID: String, line: UInt) -> Int {
        state.withLock { state in
            let site = Site(attempt: attempt, fileID: fileID, line: line)
            let ordinal = state.ordinals[site, default: 0]
            state.ordinals[site] = ordinal + 1
            return ordinal
        }
    }

    private static func bit(_ attempt: Int) -> UInt64 {
        1 << UInt64(attempt & 63)
    }
}

/// The attempt running in the current task, and the operation it belongs to.
///
/// An attempt's context goes stale when the attempt ends, so a task that an
/// attempt left running (an unstructured `Task {}` inherits task-locals)
/// does not make every later retry it starts look nested.
struct RetryContext: Sendable {
    let operation: OperationIdentity
    let attempt: Int

    @TaskLocal static var active: RetryContext?

    /// Whether a retry's (or a hedge's) attempt is running in the current
    /// task right now.
    static var isInsideAttempt: Bool {
        guard let active else { return false }
        return active.operation.isLive(attempt: active.attempt)
    }
}
