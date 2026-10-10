/// Why a piece of JSON was refused, and where.
///
/// Everything a caller needs to act on the failure is a separate field:
/// `code` is stable and meant for programs (a UI choosing which hint to
/// show, a test asserting on the cause), `location` and `path` say where,
/// and `message` is for people, with the specifics a code cannot carry.
/// Messages may be reworded between releases; codes may not.
public struct JSONParseError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A stable, machine-readable cause.
    ///
    /// A struct rather than an enum so new causes can be added without
    /// breaking anyone's exhaustive `switch`; compare against the static
    /// members.
    public struct Code: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// A character that cannot appear here.
        public static let unexpectedCharacter = Code(rawValue: "unexpected_character")
        /// The input ended in the middle of a value.
        public static let unexpectedEnd = Code(rawValue: "unexpected_end")
        /// The input is empty, or only whitespace (and comments, in `.jsonc`).
        public static let emptyInput = Code(rawValue: "empty_input")
        /// Something other than whitespace follows the root value.
        public static let trailingContent = Code(rawValue: "trailing_content")
        /// A comma before the closing bracket of an array or object, in
        /// the strict dialect.
        public static let trailingComma = Code(rawValue: "trailing_comma")
        /// A comment in the strict dialect.
        public static let commentNotAllowed = Code(rawValue: "comment_not_allowed")
        /// A `/*` comment with no `*/`.
        public static let unterminatedComment = Code(rawValue: "unterminated_comment")
        /// A byte order mark when `allowBOM` is off.
        public static let byteOrderMark = Code(rawValue: "byte_order_mark")

        /// A string with no closing quote.
        public static let unterminatedString = Code(rawValue: "unterminated_string")
        /// A backslash followed by a character that is not an escape.
        public static let invalidEscape = Code(rawValue: "invalid_escape")
        /// A `\u` escape without four hexadecimal digits.
        public static let invalidUnicode = Code(rawValue: "invalid_unicode")
        /// A `\u` surrogate escape that is not half of a correctly ordered pair.
        public static let loneSurrogate = Code(rawValue: "lone_surrogate")
        /// An unescaped control character (below U+0020) inside a string.
        public static let controlCharacter = Code(rawValue: "control_character")
        /// Bytes that are not well-formed UTF-8: overlong forms, encoded
        /// surrogates, values above U+10FFFF, truncated sequences, stray
        /// continuation bytes.
        public static let invalidUTF8 = Code(rawValue: "invalid_utf8")

        /// A number that does not match the JSON grammar.
        public static let invalidNumber = Code(rawValue: "invalid_number")
        /// A well-formed number outside the range of a `Double` (`1e400`,
        /// and `1e-400`, which would round to zero).
        public static let numberOutOfRange = Code(rawValue: "number_out_of_range")

        /// An object repeats a key and the policy is `.reject`.
        public static let duplicateKey = Code(rawValue: "duplicate_key")

        /// Nesting deeper than `maxDepth`.
        public static let depthLimit = Code(rawValue: "depth_limit")
        /// Input longer than `maxBytes`.
        public static let sizeLimit = Code(rawValue: "size_limit")
        /// A string longer than `maxStringBytes`.
        public static let stringLimit = Code(rawValue: "string_limit")
        /// A container with more than `maxContainerCount` elements.
        public static let containerLimit = Code(rawValue: "container_limit")

        public var description: String { rawValue }
    }

    public let code: Code

    /// Where the problem is. For a string that never ends, where it began;
    /// for input that ends too soon, the end of the input.
    public let location: SourceLocation

    /// The value being read when the problem was found. Inside an array it
    /// names the element being read or about to be read.
    public let path: JSONPath

    /// A sentence for a person, with context a code cannot carry.
    public let message: String

    /// A second place the message refers to: for a duplicate key, the first
    /// occurrence.
    public let related: SourceLocation?

    public init(
        code: Code,
        location: SourceLocation,
        path: JSONPath,
        message: String,
        related: SourceLocation? = nil
    ) {
        self.code = code
        self.location = location
        self.path = path
        self.message = message
        self.related = related
    }

    /// `code at line:column (path): message`.
    public var description: String {
        "\(code) at \(location) (\(path)): \(message)"
    }
}
