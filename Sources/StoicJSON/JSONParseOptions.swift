/// How strictly, and within what limits, JSON is read.
///
/// The defaults are for input that crosses a trust boundary: the strict
/// dialect, duplicate keys rejected, and limits that stop a small hostile
/// document from costing more than a small amount of memory or time. Loosen
/// them deliberately, for a source you trust, not by default.
public struct JSONParseOptions: Sendable, Hashable {
    /// Which grammar to accept.
    public enum Dialect: Sendable, Hashable {
        /// RFC 8259 and nothing else.
        case strict
        /// RFC 8259 plus `//` and `/* */` comments and trailing commas, for
        /// files people edit by hand. Everything else stays strict: a
        /// comment is whitespace, and a trailing comma may follow the last
        /// element, once.
        case jsonc
    }

    /// What to do when an object repeats a key.
    ///
    /// RFC 8259 says only that names "SHOULD be unique" and that behaviour
    /// is unpredictable otherwise, and real parsers disagree about which
    /// value wins. A document two systems read differently is a classic
    /// source of security bugs, so the default is to refuse it.
    ///
    /// A policy that accepts a repeat does not hide it: the document lists
    /// each one (``JSONDocument/repeatedKeys``), and a reader that accepts
    /// them says so to whoever wrote the text.
    public enum DuplicateKeys: Sendable, Hashable {
        /// Fail with ``JSONParseError/Code-swift.struct/duplicateKey``.
        case reject
        /// Keep the first value; later ones are still checked for
        /// well-formedness and limits, then dropped.
        case firstWins
        /// Keep the last value, in the position of the first occurrence.
        case lastWins
    }

    public var dialect: Dialect
    public var duplicateKeys: DuplicateKeys

    /// Whether the ``Dialect/jsonc`` dialect accepts comments. On by default.
    /// Off, a comment is refused (``JSONParseError/Code-swift.struct/commentNotAllowed``,
    /// at the `/` that begins it) while trailing commas and the rest of the
    /// dialect stay: for a file people edit by hand whose writer does not keep
    /// comments, so one would be lost at the next save, and is better refused
    /// where the person can see it. The strict dialect refuses them whatever
    /// this says.
    public var allowComments = true

    /// Whether a UTF-8 byte order mark at the start of the input is skipped
    /// rather than rejected. RFC 8259 forbids producing one and permits
    /// ignoring it; editors on some platforms add one anyway. Offsets still
    /// count the BOM's three bytes; columns do not.
    public var allowBOM: Bool

    /// The deepest nesting of arrays and objects accepted. A scalar is at
    /// depth 0, `[1]` at depth 1. The parser itself uses no recursion, so
    /// this limit protects what comes after it: recursive consumers such as
    /// equality, hashing, deinitialisation and encoding of the resulting
    /// value. Default 64.
    public var maxDepth: Int

    /// The longest input accepted, in bytes (including any BOM). Default
    /// 8 MiB. Values above 4 GiB - 1 are treated as 4 GiB - 1, because
    /// source ranges are stored as 32-bit offsets.
    public var maxBytes: Int

    /// The longest string accepted, keys included, measured in UTF-8 bytes
    /// after escapes are decoded. Default 1 MiB.
    public var maxStringBytes: Int

    /// The most elements in one array, or members in one object. Default
    /// 100,000.
    public var maxContainerCount: Int

    public init(
        dialect: Dialect = .strict,
        duplicateKeys: DuplicateKeys = .reject,
        allowBOM: Bool = false,
        maxDepth: Int = 64,
        maxBytes: Int = 8 * 1024 * 1024,
        maxStringBytes: Int = 1024 * 1024,
        maxContainerCount: Int = 100_000
    ) {
        self.dialect = dialect
        self.duplicateKeys = duplicateKeys
        self.allowBOM = allowBOM
        self.maxDepth = maxDepth
        self.maxBytes = maxBytes
        self.maxStringBytes = maxStringBytes
        self.maxContainerCount = maxContainerCount
    }

    /// Strict RFC 8259 with the default limits: for wire data.
    public static var strict: JSONParseOptions { JSONParseOptions() }

    /// Comments, trailing commas and a tolerated BOM, with the default
    /// limits: for hand-edited configuration files.
    public static var jsonc: JSONParseOptions {
        JSONParseOptions(dialect: .jsonc, allowBOM: true)
    }
}
