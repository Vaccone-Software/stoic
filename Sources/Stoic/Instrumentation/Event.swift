/// A decision a Stoic primitive made, reported as structured data.
///
/// Every primitive reports what it decides — retrying, giving up, abandoning,
/// restarting — because a silent decision is a bug. Event names are stable
/// API: dashboards and log queries built on them keep working across minor
/// versions, and renaming one is a breaking change.
public struct Event: Sendable, CustomStringConvertible {
    /// The event's stable name, such as `retry.exhausted`.
    public let name: EventName

    /// How loudly the event should be reported.
    public let level: Level

    /// The label of the primitive instance that decided, when it has one.
    public let label: String?

    /// The event's data, in the order the primitive recorded it.
    public let fields: [Field]

    /// Where the primitive was called from.
    public let fileID: String
    public let line: UInt

    /// The span the event happened in (``withSpan(_:_:fileID:line:operation:)``),
    /// so a sink can tie a decision to the operation it was part of. `nil`
    /// outside any span. A span's own `span.started` and `span.ended` events
    /// carry the span they describe.
    public let span: SpanContext?

    public init(
        _ name: EventName,
        level: Level = .info,
        label: String? = nil,
        fields: [Field] = [],
        fileID: String = #fileID,
        line: UInt = #line,
        span: SpanContext? = Span.current?.context
    ) {
        self.name = name
        self.level = level
        self.label = label
        self.fields = fields
        self.fileID = fileID
        self.line = line
        self.span = span
    }

    /// The value of the first field named `key`.
    public subscript(key: String) -> Value? {
        fields.first { $0.key == key }?.value
    }

    /// Severity, matching the levels of OSLog and swift-log.
    public enum Level: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
        case debug, info, notice, warning, error

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var description: String {
            switch self {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .warning: "warning"
            case .error: "error"
            }
        }
    }

    /// One named value.
    public struct Field: Sendable, CustomStringConvertible {
        public let key: String
        public let value: Value
        public let privacy: Privacy

        public init(_ key: String, _ value: Value, privacy: Privacy? = nil) {
            self.key = key
            self.value = value
            self.privacy = privacy ?? value.defaultPrivacy
        }

        public var description: String { "\(key)=\(value)" }
    }

    /// Whether a value may appear in logs collected off the device.
    ///
    /// Numbers, durations and booleans are public by default. Strings and
    /// error descriptions are private by default: they can carry user data.
    public enum Privacy: Sendable, Hashable {
        case `public`, `private`
    }

    /// A field's value.
    public enum Value: Sendable, CustomStringConvertible {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case duration(Duration)
        case error(type: String, description: String)

        /// An error value: its dynamic type name is public, its description private.
        public static func error(_ error: any Error) -> Value {
            .error(type: String(reflecting: type(of: error)), description: String(describing: error))
        }

        var defaultPrivacy: Privacy {
            switch self {
            case .string, .error: .private
            case .int, .double, .bool, .duration: .public
            }
        }

        public var description: String {
            switch self {
            case .string(let string): string
            case .int(let int): String(int)
            case .double(let double): String(double)
            case .bool(let bool): String(bool)
            case .duration(let duration): String(describing: duration)
            case .error(let type, let description): "\(type): \(description)"
            }
        }
    }

    public var description: String {
        var parts = ["\(level) \(name)"]
        if let label { parts.append("label=\(label)") }
        parts.append(contentsOf: fields.map(\.description))
        return parts.joined(separator: " ")
    }
}

/// A stable event name, such as `retry.exhausted`.
public struct EventName: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}
