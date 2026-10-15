#if canImport(os)
internal import os
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif

/// Where Stoic's events go.
///
/// `record` is called synchronously, on whatever task made the decision, so
/// a sink must not block: buffer, hand off, or drop. Stoic never awaits an
/// instrumentation call, so a slow sink can cost latency but never deadlock
/// a primitive.
public protocol Instrumentation: Sendable {
    func record(_ event: Event)

    /// Whether events at `level` would be kept. Primitives on hot paths ask
    /// before building a debug event, so a sink that drops them costs
    /// nothing. Defaults to `true`.
    func isEnabled(_ level: Event.Level) -> Bool
}

extension Instrumentation {
    public func isEnabled(_ level: Event.Level) -> Bool { true }
}

/// Discards every event.
public struct NoInstrumentation: Instrumentation {
    public init() {}
    public func record(_ event: Event) {}
    public func isEnabled(_ level: Event.Level) -> Bool { false }
}

/// Where events go when nobody chose: the unified logging system on Apple
/// platforms, standard error elsewhere. Never nowhere: a decision nobody can
/// see is a bug (DESIGN.md, principle 7).
@usableFromInline
func platformDefaultInstrumentation() -> any Instrumentation {
    #if canImport(os)
    OSLogInstrumentation()
    #else
    StandardErrorInstrumentation()
    #endif
}

#if canImport(os)
/// Writes events to the unified logging system, subsystem `stoic`.
///
/// Event names, levels, labels and public fields are visible in collected
/// logs; private fields (strings, error descriptions) are redacted outside
/// a debugger, as OSLog does for any private interpolation.
public struct OSLogInstrumentation: Instrumentation {
    private let logger: Logger
    private let minimumLevel: Event.Level

    public init(subsystem: String = "stoic", category: String = "events", minimumLevel: Event.Level = .info) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.minimumLevel = minimumLevel
    }

    public func isEnabled(_ level: Event.Level) -> Bool {
        level >= minimumLevel
    }

    public func record(_ event: Event) {
        guard event.level >= minimumLevel else { return }
        var publicPart: [String] = []
        var privatePart: [String] = []
        if let label = event.label { publicPart.append("label=\(label)") }
        for field in event.fields {
            switch field.privacy {
            case .public: publicPart.append(field.description)
            case .private: privatePart.append(field.description)
            }
        }
        let name = event.name.rawValue
        let open = publicPart.joined(separator: " ")
        let redacted = privatePart.joined(separator: " ")
        logger.log(level: event.level.osLogType, "\(name, privacy: .public) \(open, privacy: .public) \(redacted, privacy: .private)")
    }
}

extension Event.Level {
    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .error
        case .error: .fault
        }
    }
}
#else
/// The default sink without unified logging (Linux): one line per event on
/// standard error, private fields redacted as OSLog would redact them.
struct StandardErrorInstrumentation: Instrumentation {
    let minimumLevel: Event.Level = .info

    func isEnabled(_ level: Event.Level) -> Bool {
        level >= minimumLevel
    }

    func record(_ event: Event) {
        guard event.level >= minimumLevel else { return }
        var parts = ["stoic", "\(event.level)", event.name.rawValue]
        if let label = event.label { parts.append("label=\(label)") }
        for field in event.fields {
            parts.append(field.privacy == .public ? field.description : "\(field.key)=<private>")
        }
        let line = parts.joined(separator: " ") + "\n"
        // `write(2)` rather than `stderr`, a C global Swift 6 cannot prove
        // safe. Unsafe, justified: the buffer lives for the whole call, and
        // the count leaves out the C string's terminator.
        _ = line.utf8CString.withUnsafeBufferPointer { unsafe write(2, $0.baseAddress, $0.count - 1) }
    }
}
#endif

/// Fans one event out to several sinks, in order.
public struct CompositeInstrumentation: Instrumentation {
    public let sinks: [any Instrumentation]

    public init(_ sinks: [any Instrumentation]) {
        self.sinks = sinks
    }

    public func record(_ event: Event) {
        for sink in sinks where sink.isEnabled(event.level) { sink.record(event) }
    }

    public func isEnabled(_ level: Event.Level) -> Bool {
        sinks.contains { $0.isEnabled(level) }
    }
}
