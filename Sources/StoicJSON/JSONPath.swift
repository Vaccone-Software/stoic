/// The route from the root of a document to one value.
///
/// Issues, errors and source ranges are all addressed by path, so a path has
/// to be cheap to build, comparable, and printable in the two notations
/// people already know:
///
/// - ``description`` renders `$.network.hosts[3]`, which reads well in an
///   error message. Keys that are not plain identifiers are quoted, as in
///   `$["scroll speed"]`.
/// - ``pointer`` renders RFC 6901 JSON Pointer, `/network/hosts/3`, which
///   other tools (JSON Patch, JSON Schema tooling, editors) accept.
///
/// Keys compare by Unicode scalars, like object keys do.
public struct JSONPath: Sendable, Hashable, RandomAccessCollection, ExpressibleByArrayLiteral,
    CustomStringConvertible
{
    public enum Component: Sendable, Hashable {
        case key(String)
        case index(Int)

        public static func == (lhs: Component, rhs: Component) -> Bool {
            switch (lhs, rhs) {
            case (.key(let a), .key(let b)): a.utf8.elementsEqual(b.utf8)
            case (.index(let a), .index(let b)): a == b
            default: false
            }
        }

        public func hash(into hasher: inout Hasher) {
            switch self {
            case .key(let key):
                hasher.combine(0 as UInt8)
                ExactString(key).hash(into: &hasher)
            case .index(let index):
                hasher.combine(1 as UInt8)
                hasher.combine(index)
            }
        }
    }

    public var components: [Component]

    public init(_ components: [Component] = []) {
        self.components = components
    }

    public init(arrayLiteral elements: Component...) {
        components = elements
    }

    /// The path of the document root.
    public static var root: JSONPath { JSONPath() }

    // MARK: Collection

    public var startIndex: Int { 0 }
    public var endIndex: Int { components.count }
    public subscript(position: Int) -> Component { components[position] }

    /// This path extended by one object key.
    public func appending(key: String) -> JSONPath {
        JSONPath(components + [.key(key)])
    }

    /// This path extended by one array index.
    public func appending(index: Int) -> JSONPath {
        JSONPath(components + [.index(index)])
    }

    /// The path of the container, or `nil` at the root.
    public var parent: JSONPath? {
        isEmpty ? nil : JSONPath(Array(components.dropLast()))
    }

    // MARK: Rendering

    /// `$.a.b[3]`. Keys that are not identifiers (ASCII letters, digits,
    /// `_` and `$`, not starting with a digit) are written `["a b"]`, with
    /// the same escapes JSON strings use.
    public var description: String {
        var out = "$"
        for component in components {
            switch component {
            case .index(let index):
                out += "[\(index)]"
            case .key(let key):
                if Self.isIdentifier(key) {
                    out += "." + key
                } else {
                    var quoted: [UInt8] = []
                    JSONWriter.appendQuoted(key, to: &quoted)
                    out += "[" + String(decoding: quoted, as: UTF8.self) + "]"
                }
            }
        }
        return out
    }

    private static func isIdentifier(_ key: String) -> Bool {
        var first = true
        for byte in key.utf8 {
            let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            let isOther = byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$")
            let isDigit = byte >= 0x30 && byte <= 0x39
            guard isLetter || isOther || (isDigit && !first) else { return false }
            first = false
        }
        return !first
    }

    /// RFC 6901 JSON Pointer: `""` for the root, otherwise `/` before every
    /// token, with `~` written `~0` and `/` written `~1`.
    public var pointer: String {
        var out = ""
        for component in components {
            out += "/"
            switch component {
            case .index(let index):
                out += String(index)
            case .key(let key):
                for scalar in key.unicodeScalars {
                    switch scalar {
                    case "~": out += "~0"
                    case "/": out += "~1"
                    default: out.unicodeScalars.append(scalar)
                    }
                }
            }
        }
        return out
    }

    /// Reads an RFC 6901 JSON Pointer. Returns `nil` if `pointer` is
    /// malformed: not empty and not starting with `/`, or containing `~`
    /// followed by anything but `0` or `1`.
    ///
    /// A pointer does not say whether `/3` means the key `"3"` or the index
    /// 3; only the document knows. Without `root`, a token made of digits
    /// (no leading zero, small enough for an `Int`) becomes an index and any
    /// other token a key, which is wrong for an object with numeric keys.
    /// Pass the document's root value and the path is resolved against it: a
    /// digit token is an index only where the value is an array. Where the
    /// path leaves the document, the digit rule applies.
    public init?(pointer: String, resolvingAgainst root: JSONValue? = nil) {
        if pointer.isEmpty {
            self.init()
            return
        }
        guard pointer.utf8.first == UInt8(ascii: "/") else { return nil }
        var components: [Component] = []
        var current = root
        for rawToken in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard let token = Self.unescapePointerToken(rawToken) else { return nil }
            let digitIndex = Self.arrayIndex(token)
            let component: Component
            switch current {
            case .array?:
                guard let digitIndex else { component = .key(token); break }
                component = .index(digitIndex)
            case .object?:
                component = .key(token)
            default:
                component = digitIndex.map(Component.index) ?? .key(token)
            }
            components.append(component)
            current = current?.step(component)
        }
        self.init(components)
    }

    private static func unescapePointerToken(_ token: Substring) -> String? {
        var out = ""
        var scalars = token.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == "~" {
                switch scalars.next() {
                case "0": out += "~"
                case "1": out += "/"
                default: return nil
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// RFC 6901 array indexes: `0`, or digits without a leading zero.
    private static func arrayIndex(_ token: String) -> Int? {
        guard let first = token.utf8.first, token.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        if first == UInt8(ascii: "0"), token.utf8.count > 1 { return nil }
        return Int(token)
    }
}

extension JSONValue {
    /// The child one component down, or `nil`.
    fileprivate func step(_ component: JSONPath.Component) -> JSONValue? {
        switch (component, self) {
        case (.key(let key), .object(let object)): object[key]
        case (.index(let index), .array(let array)): array.indices.contains(index) ? array[index] : nil
        default: nil
        }
    }
}
