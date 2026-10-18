/// A key an object said more than once, in text a parse accepted anyway.
///
/// From ``JSONDocument/repeatedKeys``. The parser's default is to refuse a
/// repeat (``JSONParseOptions/DuplicateKeys/reject``); for a file a person
/// edits, where the later line is most likely the one they meant, a reader may
/// choose to keep one occurrence (``JSONParseOptions/DuplicateKeys/lastWins``).
/// This is what such a reader owes the person in return: where the key was
/// said, and which one it used.
public struct JSONRepeatedKey: Sendable, Hashable {
    /// Which occurrence is the value.
    public enum Kept: Sendable, Hashable {
        /// The first. Later ones were read and dropped.
        case first
        /// The last, in the position of the first.
        case last
    }

    /// Where the repeated member is: the path of the object, then the key.
    public let path: JSONPath

    /// The key.
    public let key: String

    /// Where the key was first said.
    public let first: SourceLocation

    /// The key at this repeat, quotes included.
    public let repeated: SourceRange

    /// Which occurrence the value holds.
    public let kept: Kept

    public init(path: JSONPath, key: String, first: SourceLocation, repeated: SourceRange, kept: Kept) {
        self.path = path
        self.key = key
        self.first = first
        self.repeated = repeated
        self.kept = kept
    }
}
