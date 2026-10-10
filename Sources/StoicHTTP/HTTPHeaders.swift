/// A request's or response's header fields: case-insensitive names, values
/// kept in the order they were added.
///
/// A header can hold a secret, and a value that is printed once is a value
/// in a log. So `description` and `debugDescription` show the names of
/// ``sensitiveNames`` with their values replaced by `<redacted>`; only an
/// explicit subscript read returns the value.
public struct HTTPHeaders: Sendable, Hashable, ExpressibleByDictionaryLiteral, Sequence, CustomStringConvertible, CustomDebugStringConvertible {
    /// One header line.
    public struct Field: Sendable, Hashable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// The headers whose values never appear in an event, a description or a
    /// log: credentials and cookies, lower case.
    public static let sensitiveNames: Set<String> = ["authorization", "cookie", "set-cookie", "proxy-authorization"]

    /// Whether `name` is one of ``sensitiveNames``, ignoring case.
    public static func isSensitive(_ name: String) -> Bool {
        sensitiveNames.contains(name.lowercased())
    }

    /// The fields, in the order added.
    public private(set) var fields: [Field]

    public init() {
        fields = []
    }

    public init(_ fields: [Field]) {
        self.fields = fields
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        fields = elements.map { Field(name: $0.0, value: $0.1) }
    }

    public init(_ pairs: [(String, String)]) {
        fields = pairs.map { Field(name: $0.0, value: $0.1) }
    }

    /// The first value of the header called `name`, or `nil`. Setting
    /// replaces every field with that name; setting `nil` removes them.
    public subscript(name: String) -> String? {
        get { fields.first { $0.name.caseInsensitiveEquals(name) }?.value }
        set {
            fields.removeAll { $0.name.caseInsensitiveEquals(name) }
            if let newValue { fields.append(Field(name: name, value: newValue)) }
        }
    }

    /// Adds a field, keeping any with the same name (a header such as
    /// `Accept` may legitimately repeat).
    public mutating func add(_ name: String, _ value: String) {
        fields.append(Field(name: name, value: value))
    }

    /// Every value of the header called `name`, in order.
    public func values(for name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveEquals(name) }.map(\.value)
    }

    /// Whether any field is called `name`.
    public func contains(_ name: String) -> Bool {
        fields.contains { $0.name.caseInsensitiveEquals(name) }
    }

    public var isEmpty: Bool { fields.isEmpty }

    /// `self`, with each field of `other` replacing any field of the same name.
    public func merging(_ other: HTTPHeaders) -> HTTPHeaders {
        var merged = self
        var replaced: Set<String> = []
        for field in other.fields {
            if replaced.insert(field.name.lowercased()).inserted {
                merged.fields.removeAll { $0.name.caseInsensitiveEquals(field.name) }
            }
            merged.fields.append(field)
        }
        return merged
    }

    /// These headers without the fields named in ``sensitiveNames``.
    public func removingSensitive() -> HTTPHeaders {
        HTTPHeaders(fields.filter { !Self.isSensitive($0.name) })
    }

    public func makeIterator() -> IndexingIterator<[Field]> {
        fields.makeIterator()
    }

    public var description: String {
        let parts = fields.map { Self.isSensitive($0.name) ? "\($0.name): <redacted>" : "\($0.name): \($0.value)" }
        return "[" + parts.joined(separator: ", ") + "]"
    }

    public var debugDescription: String { description }
}

extension String {
    /// ASCII case-insensitive equality: header names are ASCII, so no
    /// locale or Unicode folding is wanted.
    fileprivate func caseInsensitiveEquals(_ other: String) -> Bool {
        utf8.count == other.utf8.count && lowercased() == other.lowercased()
    }
}
