/// Words for a person: a key to translate, and the text to show when there is
/// no translation (design/31).
///
/// The kernel has no Foundation, so it cannot look a translation up. A
/// wording carries everything a lookup needs instead: the `key`, the `table`
/// it lives in (`nil` for the app's default table; `Stoic` for Stoic's own
/// keys), the English `defaultText`, and named `arguments` for the `{name}`
/// placeholders the text holds. Arguments are typed, so a localiser formats
/// a number, a moment or a duration for the person's locale.
/// `String(localized:bundle:locale:)` in StoicFoundation does that; the
/// description here writes them plainly, untranslated.
///
///     Wording("invite.expired", default: "This link expired on {date}.", arguments: ["date": .moment(expiry)])
///
/// A wording's text and arguments are for the person and are never put in an
/// event: an argument can be their own email address.
public struct Wording: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The key a translation is looked up by.
    public let key: String

    /// The text shown when there is no translation: English for Stoic's own
    /// keys. It may hold `{name}` placeholders.
    public let defaultText: String

    /// The table the key lives in; `nil` for the app's default table.
    public let table: String?

    /// The values of the text's placeholders, by name.
    public let arguments: [String: Argument]

    /// A value a placeholder stands for, typed so it can be formatted for a
    /// locale.
    public enum Argument: Sendable, Hashable, Codable, CustomStringConvertible {
        case text(String)
        case integer(Int)
        case moment(Moment)
        case duration(Duration)

        /// The value written plainly: a moment in RFC 3339, a duration as
        /// Swift writes one.
        public var description: String {
            switch self {
            case .text(let text): text
            case .integer(let integer): String(integer)
            case .moment(let moment): moment.description
            case .duration(let duration): duration.description
            }
        }

        private enum CodingKeys: String, CodingKey {
            case text, integer, moment, duration
        }

        /// One key naming the kind: `{"integer": 3}`.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.allKeys.count == 1, let key = container.allKeys.first else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "an argument is one of {\"text\": …}, {\"integer\": …}, {\"moment\": …} or {\"duration\": …}"))
            }
            switch key {
            case .text: self = .text(try container.decode(String.self, forKey: .text))
            case .integer: self = .integer(try container.decode(Int.self, forKey: .integer))
            case .moment: self = .moment(try container.decode(Moment.self, forKey: .moment))
            case .duration: self = .duration(try container.decode(Duration.self, forKey: .duration))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text): try container.encode(text, forKey: .text)
            case .integer(let integer): try container.encode(integer, forKey: .integer)
            case .moment(let moment): try container.encode(moment, forKey: .moment)
            case .duration(let duration): try container.encode(duration, forKey: .duration)
            }
        }
    }

    public init(_ key: String, default text: String, table: String? = nil, arguments: [String: Argument] = [:]) {
        self.key = key
        self.defaultText = text
        self.table = table
        self.arguments = arguments
    }

    /// The default text, its placeholders filled with the arguments written
    /// plainly. Never translated: this is what a log or a test reads.
    public var description: String {
        filling(defaultText) { $0.description }
    }

    /// `template` with each `{name}` the arguments name replaced by
    /// `format` of that argument. A placeholder with no argument, and a brace
    /// that opens no placeholder, are left as they are.
    package func filling(_ template: String, _ format: (Argument) -> String) -> String {
        guard !arguments.isEmpty, template.contains("{") else { return template }
        var result = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            rest = rest[open...]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            let name = String(rest[afterOpen..<close])
            if let argument = arguments[name] {
                result += format(argument)
                rest = rest[rest.index(after: close)...]
            } else {
                // Not one of ours: keep the brace and look again just after it.
                result.append("{")
                rest = rest[afterOpen...]
            }
        }
        return result + rest
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case defaultText = "default"
        case table
        case arguments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        defaultText = try container.decode(String.self, forKey: .defaultText)
        table = try container.decodeIfPresent(String.self, forKey: .table)
        arguments = try container.decodeIfPresent([String: Argument].self, forKey: .arguments) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(defaultText, forKey: .defaultText)
        try container.encodeIfPresent(table, forKey: .table)
        if !arguments.isEmpty { try container.encode(arguments, forKey: .arguments) }
    }
}
