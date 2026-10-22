internal import Synchronization

/// One operation: a `retry`, a `hedge`, one run of `recur`, or one
/// `perform` of a declared operation. Every attempt at it shares it, and
/// with it the operation's idempotency key, drawn the first time an attempt
/// asks.
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
/// A declared operation's `perform` counts by its declared names instead of
/// its line, and derives its key with a frozen function
/// (``IdempotencyKey/derived(fromEnclosing:backend:operation:occurrence:)``),
/// so the key survives a relaunch and an app update (design/22, Keys).
///
/// Attempts of a hedge run at once and each counts its own ordinals, so a
/// sub-operation reached the same way by two hedged copies has one key: the
/// copies are the same operation.
///
/// **Settled attempts.** A declared operation that gives up inside an
/// attempt marks the attempt *settled*: whoever runs the attempt (`retry`,
/// `Retrying`, `hedge`, `perform`, an outbox delivery) must not repeat it,
/// whatever its classifier says (design/22, One layer retries). The mark
/// lives here, per attempt, and is set only while the attempt is live, so a
/// task an attempt left running cannot mark a later one.
final class OperationIdentity: Sendable {
    private struct Parent: Sendable {
        let identity: OperationIdentity
        let attempt: Int
        let ordinal: Int
        let derivation: Derivation
    }

    /// How a sub-operation's key comes from its parent's.
    private enum Derivation: Sendable {
        /// By call site, with a stable hash (`retry`, `hedge`, `recur`).
        case site
        /// By declared names, with the frozen SHA-256 derivation (`perform`).
        case declared(backend: String, operation: String)
    }

    /// What one attempt counts its sub-operations by.
    private struct Site: Hashable, Sendable {
        enum Place: Hashable, Sendable {
            case line(String, UInt)
            case declared(String, String)
        }

        let attempt: Int
        let place: Place
    }

    private struct State: Sendable {
        var key: IdempotencyKey?
        // Whether an attempt asked for the key: a keyed operation whose key
        // Stoic made and nobody read sent no key, and must not be repeated.
        var keyRead = false
        // Bit `n % 64` is set while attempt `n` runs. A retry runs one attempt
        // at a time, a hedge a few at once; a collision can only make a task
        // an attempt left running look nested for a while, never the reverse.
        var live: UInt64 = 0
        // Bit `n % 64`: attempt `n` was settled by an operation inside it.
        var settled: UInt64 = 0
        // Bit `n % 64`: a same-backend `perform` inside attempt `n` is
        // borrowing its admission slot.
        var borrowed: UInt64 = 0
        // Bit `n % 64`: a nested retry's attempt timed out inside attempt `n`.
        // The retry rethrows the child's cancellation; the bit is how the
        // enclosing retry tells that timer from the caller cancelling.
        var timedOut: UInt64 = 0
        var ordinals: [Site: Int] = [:]
    }

    private let fileID: String
    private let line: UInt
    private let parent: Parent?
    /// Whether the key was given (an argument, an outbox entry's key) rather
    /// than made by Stoic.
    let keyWasGiven: Bool
    private let state: Mutex<State>

    /// A top-level operation, whose key is drawn from the ambient random
    /// source at this call site when first asked for.
    init(fileID: String, line: UInt) {
        self.fileID = fileID
        self.line = line
        self.parent = nil
        self.keyWasGiven = false
        self.state = Mutex(State())
    }

    /// An operation whose key is `key`: the key made with the intent (a
    /// checkout opened, an outbox entry), so every attempt, and every
    /// operation derived from it, uses that key.
    init(key: IdempotencyKey, fileID: String, line: UInt) {
        self.fileID = fileID
        self.line = line
        self.parent = nil
        self.keyWasGiven = true
        self.state = Mutex(State(key: key))
    }

    private init(fileID: String, line: UInt, parent: Parent) {
        self.fileID = fileID
        self.line = line
        self.parent = parent
        self.keyWasGiven = false
        self.state = Mutex(State())
    }

    /// The operation starting here: a sub-operation of the attempt running
    /// in the current task, if there is one, else a top-level operation.
    static func starting(fileID: String, line: UInt) -> OperationIdentity {
        guard let context = RetryContext.active, context.operation.isLive(attempt: context.attempt) else {
            return OperationIdentity(fileID: fileID, line: line)
        }
        let ordinal = context.operation.nextOrdinal(attempt: context.attempt, place: .line(fileID, line))
        return OperationIdentity(
            fileID: fileID, line: line,
            parent: Parent(identity: context.operation, attempt: context.attempt, ordinal: ordinal, derivation: .site)
        )
    }

    /// A `perform` of the operation `name` on `backend` starting inside
    /// `context`'s live attempt: its key is derived from the enclosing key,
    /// the declared names and its occurrence among performs of that
    /// operation in the attempt.
    static func performing(backend: String, operation name: String, in context: RetryContext, fileID: String, line: UInt) -> OperationIdentity {
        let occurrence = context.operation.nextOrdinal(attempt: context.attempt, place: .declared(backend, name))
        return OperationIdentity(
            fileID: fileID, line: line,
            parent: Parent(
                identity: context.operation, attempt: context.attempt, ordinal: occurrence,
                derivation: .declared(backend: backend, operation: name)
            )
        )
    }

    /// Whether this operation started inside another's attempt.
    var isSubOperation: Bool { parent != nil }

    /// The key, as an attempt reads it: drawn or derived on first read, and
    /// remembered as read.
    var idempotencyKey: IdempotencyKey {
        key(markingRead: true)
    }

    /// The key if an attempt read it, or if it was given; `nil` for a key
    /// Stoic would have made but no attempt ever sent. Reading it does not
    /// count as sending it.
    var sentKey: IdempotencyKey? {
        if keyWasGiven { return key(markingRead: false) }
        return state.withLock { $0.keyRead ? $0.key : nil }
    }

    /// Whether an attempt read the key (always true for a given key).
    var keyWasRead: Bool {
        keyWasGiven || state.withLock { $0.keyRead }
    }

    private func key(markingRead: Bool) -> IdempotencyKey {
        // Lock order: a sub-operation's lock, then its parent's; a parent
        // never takes a child's.
        state.withLock { state in
            if markingRead { state.keyRead = true }
            if let key = state.key { return key }
            let drawn: IdempotencyKey
            if let parent {
                let enclosing = parent.identity.idempotencyKey
                switch parent.derivation {
                case .site:
                    drawn = .derived(from: enclosing, fileID: fileID, line: line, ordinal: parent.ordinal)
                case .declared(let backend, let operation):
                    drawn = .derived(fromEnclosing: enclosing, backend: backend, operation: operation, occurrence: parent.ordinal)
                }
            } else {
                drawn = .random(fileID: fileID, line: line)
            }
            state.key = drawn
            return drawn
        }
    }

    /// Runs `body` as attempt `number`, in the current task: operations it
    /// starts are sub-operations of this one, and a `retry` it starts is
    /// nested. `frame`, when given, says the attempt is a `perform`'s; by
    /// default an attempt inside a `perform`'s carries that frame on.
    nonisolated(nonsending) func running<R>(
        attempt number: Int,
        frame: PerformFrame? = RetryContext.active?.frame,
        _ body: nonisolated(nonsending) () async -> R
    ) async -> R {
        begin(attempt: number)
        defer { end(attempt: number) }
        return await RetryContext.$active.withValue(RetryContext(operation: self, attempt: number, frame: frame)) {
            await body()
        }
    }

    func begin(attempt number: Int) {
        state.withLock { state in
            state.live |= Self.bit(number)
            state.settled &= ~Self.bit(number)
            state.borrowed &= ~Self.bit(number)
            state.timedOut &= ~Self.bit(number)
        }
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

    /// Marks attempt `number` settled, if it is still running: whoever runs
    /// it must not repeat it. A stale attempt is left alone.
    func settle(attempt number: Int) {
        state.withLock { state in
            if state.live & Self.bit(number) != 0 { state.settled |= Self.bit(number) }
        }
    }

    /// Whether attempt `number` was settled while it ran.
    func isSettled(attempt number: Int) -> Bool {
        state.withLock { $0.settled & Self.bit(number) != 0 }
    }

    /// Settles the enclosing attempt this operation started in: a layer
    /// that stopped on a settled attempt passes the mark outward, so a
    /// collapsed layer in between cannot let an outer one repeat it.
    func settleEnclosingAttempt() {
        guard let parent else { return }
        parent.identity.settle(attempt: parent.attempt)
    }

    /// Forgets a timeout noted on the enclosing attempt. A nested retry
    /// clears it on entry, so a timeout that an earlier nested retry threw
    /// and the operation caught does not stick to a later failure.
    func clearEnclosingAttemptTimedOut() {
        guard let parent else { return }
        parent.identity.state.withLock { $0.timedOut &= ~Self.bit(parent.attempt) }
    }

    /// Notes that this nested retry's attempt timed out, on the attempt it
    /// runs inside. The enclosing retry reads it when the rethrown
    /// cancellation arrives: that cancellation is the timer.
    func noteEnclosingAttemptTimedOut() {
        guard let parent else { return }
        parent.identity.state.withLock { state in
            if state.live & Self.bit(parent.attempt) != 0 { state.timedOut |= Self.bit(parent.attempt) }
        }
    }

    /// Whether a nested retry noted a timeout for attempt `number`, then
    /// clears the note.
    func takeAttemptTimedOut(_ number: Int) -> Bool {
        state.withLock { state in
            let bit = Self.bit(number)
            let set = state.timedOut & bit != 0
            state.timedOut &= ~bit
            return set
        }
    }

    /// Takes attempt `number`'s admission slot for a same-backend `perform`
    /// inside it, if no other one has it; `false` when one does.
    func borrowSlot(attempt number: Int) -> Bool {
        state.withLock { state in
            guard state.borrowed & Self.bit(number) == 0 else { return false }
            state.borrowed |= Self.bit(number)
            return true
        }
    }

    /// Gives back what ``borrowSlot(attempt:)`` took.
    func returnSlot(attempt number: Int) {
        state.withLock { $0.borrowed &= ~Self.bit(number) }
    }

    private func nextOrdinal(attempt: Int, place: Site.Place) -> Int {
        state.withLock { state in
            let site = Site(attempt: attempt, place: place)
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
    /// The `perform` attempt this one runs in, if any: the backend whose
    /// slot it holds, for a nested `perform` on the same backend.
    let frame: PerformFrame?
    /// The task the attempt's work runs in. A task-local is inherited by
    /// child tasks, and a `perform` in one (a task group, an `async let`)
    /// runs in no deterministic order, so it cannot count its occurrence.
    let task: Int?

    init(operation: OperationIdentity, attempt: Int, frame: PerformFrame?) {
        self.operation = operation
        self.attempt = attempt
        self.frame = frame
        self.task = Self.currentTask
    }

    /// This context, carried into a task that runs the attempt's work on its
    /// own (a deadline's single child): the work is still the attempt's.
    func carried() -> RetryContext {
        RetryContext(operation: operation, attempt: attempt, frame: frame)
    }

    @TaskLocal static var active: RetryContext?

    /// Whether the attempt is still running.
    var isLive: Bool {
        operation.isLive(attempt: attempt)
    }

    /// Whether the current task is the one the attempt's work runs in,
    /// rather than a child task of it.
    var isCurrentTask: Bool {
        task == Self.currentTask
    }

    /// Whether a retry's (or a hedge's) attempt is running in the current
    /// task right now.
    static var isInsideAttempt: Bool {
        guard let active else { return false }
        return active.isLive
    }

    /// The identity of the current task, or `nil` outside one.
    private static var currentTask: Int? {
        // Unsafe, justified: the task is hashed and nothing else; it is not
        // retained, resumed or used past the closure. The hash is unique among
        // tasks alive at once, and the attempt's task outlives its context.
        unsafe withUnsafeCurrentTask { task in unsafe task?.hashValue }
    }
}
