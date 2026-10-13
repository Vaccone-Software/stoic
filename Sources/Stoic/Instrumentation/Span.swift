/// A span's identity: 64 bits drawn from the ambient ``RandomSource``, so a
/// seeded test sees the same ids on every run.
///
/// Not a W3C trace context: Stoic's spans live in one process. An adapter
/// that exports to a tracing backend widens or maps the ids itself.
public struct SpanID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Sixteen lowercase hex digits.
    public var description: String {
        let digits = String(rawValue, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

/// Where a span sits in its trace.
public struct SpanContext: Hashable, Sendable, CustomStringConvertible {
    /// The id of the root span of the tree this span belongs to.
    public let traceID: SpanID
    public let id: SpanID
    /// The enclosing span's id; `nil` for a root.
    public let parentID: SpanID?

    public init(traceID: SpanID, id: SpanID, parentID: SpanID?) {
        self.traceID = traceID
        self.id = id
        self.parentID = parentID
    }

    public var description: String {
        "span \(id) trace \(traceID)" + (parentID.map { " parent \($0)" } ?? "")
    }
}

/// The span the current task is running in.
///
/// A span is a named, timed stretch of work with a parent. ``withSpan(_:_:fileID:line:operation:)``
/// opens one; it is the task-local ``current`` for the operation and for
/// every task the operation starts that inherits task-locals: child tasks,
/// `async let`, `Task {}`, and the forks, races and flights of Stoic's
/// scopes. A `Task.detached` inherits nothing and so starts a new trace.
public struct Span: Sendable {
    public let name: String
    public let context: SpanContext
    /// When the span began, on the ambient clock.
    public let startedAt: AnyClock.Instant

    @TaskLocal static var stored: Span?

    /// The span in force for the current task, if any.
    public static var current: Span? { stored }
}

/// How a span ended.
public enum SpanStatus: String, Sendable, Hashable, CustomStringConvertible {
    /// The operation returned.
    case ok
    /// The operation threw something that is not a cancellation.
    case error
    /// The operation was cancelled. Not a failure: nobody is paged for it.
    case cancelled

    public var description: String { rawValue }
}

/// Runs `operation` inside a span named `name`, reporting when it starts and
/// when it ends.
///
///     let user = try await withSpan("sync.fetch_user", [.init("user", .string(id), privacy: .public)]) {
///         try await api.user(id)
///     }
///
/// A span is two events through the ambient instrumentation, so tracing
/// needs no machinery of its own and reaches every sink:
///
/// - `span.started` carries `span`, `trace`, `parent` (absent for a root)
///   and `name`, then `attributes`.
/// - `span.ended` carries the same, then `duration` and `status`
///   (``SpanStatus``), and `error` when the status is `error`. The duration
///   is measured on the **ambient clock**, so on a test clock it is exact.
///
/// The keys `span`, `trace`, `parent`, `name`, `duration`, `status` and
/// `error` are the span's; do not use them as attribute keys. Attributes keep
/// their own privacy; ids, name and status are public. Keep `name` short and
/// low-cardinality (it becomes a metrics dimension); put the high-cardinality
/// part in an attribute.
///
/// An error thrown by `operation` is recorded as status `error` and
/// rethrown unchanged. A cancellation, whether a `CancellationError`, a
/// ``Report`` of one, or a policy's cancelled ``Rejection``, is status
/// `cancelled`, not an error.
///
/// Both events are `debug` level. When the ambient instrumentation drops
/// debug events (the default `OSLogInstrumentation` does), `withSpan` reads
/// one flag and runs `operation`: no ids are drawn, no task-local is bound,
/// nothing is allocated.
public nonisolated(nonsending) func withSpan<R, Failure: Error>(
    _ name: String,
    _ attributes: [Event.Field] = [],
    fileID: String = #fileID,
    line: UInt = #line,
    operation: nonisolated(nonsending) () async throws(Failure) -> R
) async throws(Failure) -> R {
    let ambient = Ambient.current
    let sink = ambient.instrumentation
    guard sink.isEnabled(.debug) else { return try await operation() }

    let parent = Span.current?.context
    var generator = ambient.random.generator(discriminator: ambient.random.nextDraw(), fileID: fileID, line: line)
    let id = SpanID(rawValue: generator.next() | 1)   // never zero, the "no span" value of most backends
    let context = SpanContext(traceID: parent?.traceID ?? id, id: id, parentID: parent?.id)
    let clock = ambient.clock
    let started = clock.now
    let span = Span(name: name, context: context, startedAt: started)
    let head = span.headFields + attributes

    sink.record(Event("span.started", level: .debug, fields: head, fileID: fileID, line: line, span: context))
    let outcome: Result<R, Failure> = await Span.$stored.withValue(span) {
        do throws(Failure) {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    let status: SpanStatus
    var tail: [Event.Field] = [.init("duration", .duration(started.duration(to: clock.now)))]
    switch outcome {
    case .success:
        status = .ok
    case .failure(let error):
        if containsCancellation(error) {
            status = .cancelled
        } else {
            status = .error
            tail.append(.init("error", .error(error)))
        }
    }
    tail.insert(.init("status", .string(status.rawValue), privacy: .public), at: 1)
    sink.record(Event("span.ended", level: .debug, fields: head + tail, fileID: fileID, line: line, span: context))
    return try outcome.get()
}

extension Span {
    /// The fields that identify the span, first in both of its events.
    fileprivate var headFields: [Event.Field] {
        var fields: [Event.Field] = [
            .init("span", .string(context.id.description), privacy: .public),
            .init("trace", .string(context.traceID.description), privacy: .public),
        ]
        if let parent = context.parentID { fields.append(.init("parent", .string(parent.description), privacy: .public)) }
        fields.append(.init("name", .string(name), privacy: .public))
        return fields
    }
}
