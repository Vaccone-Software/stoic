#if STOIC_LOGGING
public import Logging
public import Stoic

/// Sends Stoic's events to swift-log.
///
/// Each event becomes one log message whose text is the event's stable name
/// and whose metadata carries its label, fields and source location. swift-log
/// has no notion of privacy, so private fields — strings and error
/// descriptions, by Stoic's defaults — are written as `<private>` unless
/// `includePrivate` is set: a log backend is not a place to discover that an
/// error description contained a user's data.
///
/// **Spans.** An event recorded inside a span (``withSpan(_:_:fileID:line:operation:)``)
/// carries `span`, `trace` and `parent` (absent on a root) in its metadata,
/// so a backend can group a request's log lines. `span.started` and
/// `span.ended` are ordinary messages whose metadata holds the span's `name`,
/// its attributes and, on the end, `status` and `duration` (in seconds).
///
///     withAmbient({ $0.instrumentation = SwiftLogInstrumentation(logger: Logger(label: "app.stoic")) }) { … }
public struct SwiftLogInstrumentation: Instrumentation {
    public let logger: Logger
    public let includePrivate: Bool

    public init(logger: Logger, includePrivate: Bool = false) {
        self.logger = logger
        self.includePrivate = includePrivate
    }

    /// A span's duration as plain seconds, which a log backend can sort and
    /// sum; every other value as it describes itself.
    private func describe(_ field: Event.Field, in event: Event) -> String {
        if event.name == "span.ended", case .duration(let duration) = field.value {
            let parts = duration.components
            return String(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
        return field.value.description
    }

    public func record(_ event: Event) {
        var metadata: Logger.Metadata = [:]
        if let span = event.span {
            metadata["span"] = .string(span.id.description)
            metadata["trace"] = .string(span.traceID.description)
            if let parent = span.parentID { metadata["parent"] = .string(parent.description) }
        }
        if let label = event.label { metadata["label"] = .string(label) }
        for field in event.fields {
            metadata[field.key] = field.privacy == .private && !includePrivate ? "<private>" : .string(describe(field, in: event))
        }
        logger.log(
            level: event.level.swiftLogLevel,
            "\(event.name.rawValue)",
            metadata: metadata,
            source: "Stoic",
            file: event.fileID,
            function: "",
            line: event.line
        )
    }
}

extension Event.Level {
    var swiftLogLevel: Logger.Level {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .warning: .warning
        case .error: .error
        }
    }
}
#endif
