public import StoicJSON

/// How a decode treats a document that is not quite right.
public struct DecodeOptions: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        /// Any error fails the decode and produces no value. For wire
        /// formats, where a half-understood message is worse than none.
        case strict
        /// An invalid field falls back to its default and records a
        /// `repaired` issue, so the app starts and the user is told what
        /// was ignored. For hand-edited configuration. Also accepts `1.0`
        /// for an integer, with a warning. A field with no default (or a
        /// value outside any field) cannot be repaired and stays an error.
        case lenient
    }

    public var mode: Mode

    /// How text is parsed by the entry points that take bytes or a string.
    public var parse: JSONParseOptions

    /// The most issues one decode records. Past it the decode carries on
    /// (so it is still rejected correctly) but stops writing issues down,
    /// and says so once with ``IssueCode/tooManyIssues``. A hostile
    /// document with a million bad elements should cost a million checks,
    /// not a million strings.
    public var maxIssues: Int

    public init(mode: Mode = .strict, parse: JSONParseOptions = .strict, maxIssues: Int = 1000) {
        self.mode = mode
        self.parse = parse
        self.maxIssues = maxIssues
    }

    /// Strict decoding of strict JSON.
    public static var strict: DecodeOptions { DecodeOptions() }

    /// Lenient decoding of JSON with comments and trailing commas: the
    /// preset for a configuration file a person edits.
    public static var lenient: DecodeOptions {
        DecodeOptions(mode: .lenient, parse: .jsonc)
    }
}

/// The outcome of a decode: a value if there were no errors, and every issue
/// found either way.
///
/// Decoding never stops at the first problem, so `issues` is the whole list
/// for this input. Decoded from text, it is in reading order (see
/// ``Swift/Array/inReadingOrder()``); otherwise in the order the schema found
/// them (declaration order within an object, element order within an array).
public struct Decoded<Value: Sendable>: Sendable {
    /// The decoded value. `nil` if any issue is an error.
    public var value: Value?
    public var issues: [Issue]

    public init(value: Value?, issues: [Issue]) {
        self.value = value
        self.issues = issues
    }

    public var errors: [Issue] { issues.filter { $0.severity == .error } }
    public var warnings: [Issue] { issues.filter { $0.severity == .warning } }
    public var repairs: [Issue] { issues.filter { $0.severity == .repaired } }

    /// The value, or every issue as one error.
    public func get() throws(ValidationFailure) -> Value {
        guard let value else { throw ValidationFailure(issues: issues) }
        return value
    }
}

/// How a value is written back out.
public struct EncodeStyle: Sendable, Hashable {
    public enum Density: Sendable, Hashable {
        /// Every field.
        case full
        /// Only the fields that differ from their default: the shape of a
        /// hand-edited configuration file, and a fixed point of
        /// decode-then-encode.
        case sparse
    }

    public var density: Density

    /// Whether fields declared `secret` are written. Off for ``sparse``
    /// because a sparse file is what lands in a repository or a bug report;
    /// on for ``full`` because a full encoding is the faithful copy a
    /// store or a transport needs. Say so deliberately either way.
    public var includeSecrets: Bool

    public init(_ density: Density, includeSecrets: Bool) {
        self.density = density
        self.includeSecrets = includeSecrets
    }

    /// Every field, secrets included.
    public static var full: EncodeStyle { EncodeStyle(.full, includeSecrets: true) }

    /// Only fields that differ from their default, secrets left out.
    public static var sparse: EncodeStyle { EncodeStyle(.sparse, includeSecrets: false) }

    /// Sparse, with secrets written if asked.
    public static func sparse(includeSecrets: Bool) -> EncodeStyle {
        EncodeStyle(.sparse, includeSecrets: includeSecrets)
    }

    /// Every field, with secrets left out.
    public static var fullWithoutSecrets: EncodeStyle { EncodeStyle(.full, includeSecrets: false) }
}
