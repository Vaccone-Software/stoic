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
///     withAmbient({ $0.instrumentation = SwiftLogInstrumentation(logger: Logger(label: "app.stoic")) }) { … }
public struct SwiftLogInstrumentation: Instrumentation {
    public let logger: Logger
    public let includePrivate: Bool

    public init(logger: Logger, includePrivate: Bool = false) {
        self.logger = logger
        self.includePrivate = includePrivate
    }

    public func record(_ event: Event) {
        var metadata: Logger.Metadata = [:]
        if let label = event.label { metadata["label"] = .string(label) }
        for field in event.fields {
            metadata[field.key] = field.privacy == .private && !includePrivate ? "<private>" : .string(field.value.description)
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
