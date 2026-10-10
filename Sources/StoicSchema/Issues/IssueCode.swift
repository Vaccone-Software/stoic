/// What kind of problem an ``Issue`` reports.
///
/// Codes are the contract between the validator and everything that reacts
/// to it: a settings screen that binds a message to the field at the issue's
/// path, a test that asserts on the cause, a log pipeline that counts
/// failures by kind. So they are short, `snake_case`, and stable: a message
/// may be reworded between releases, a code may not.
///
/// A struct rather than an enum, like `Rejection.Reason` in the core module,
/// so a new kind of problem can be added without breaking anyone's
/// exhaustive `switch`, and so a constraint outside this module (a
/// ``Constraint/custom(id:description:check:)`` or a later migration step)
/// can mint its own code. Compare against the static members.
public struct IssueCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: Shape

    /// The value is a different kind of JSON value than the schema wants:
    /// a string where a number belongs, `1.5` where an integer does.
    public static let typeMismatch = IssueCode(rawValue: "type_mismatch")
    /// A required key is absent.
    public static let missingKey = IssueCode(rawValue: "missing_key")
    /// A key the object does not declare.
    public static let unknownKey = IssueCode(rawValue: "unknown_key")
    /// A key that is accepted but should not be written any more: a
    /// deprecated field, or an old spelling of a current one.
    public static let deprecatedKey = IssueCode(rawValue: "deprecated_key")
    /// One field was given under two spellings (`scrollSpeed` and
    /// `scroll_speed`). Which one wins would be a guess, so neither does.
    public static let duplicateKey = IssueCode(rawValue: "duplicate_key")

    // MARK: Constraints

    /// A number outside the bounds of a ``Constraint/range(_:)``, or an
    /// integer that does not fit its Swift type.
    public static let outOfRange = IssueCode(rawValue: "out_of_range")
    /// A string shorter than its length constraint allows.
    public static let tooShort = IssueCode(rawValue: "too_short")
    /// A string longer than its length constraint allows.
    public static let tooLong = IssueCode(rawValue: "too_long")
    /// A collection with fewer elements than its count constraint allows.
    public static let tooFew = IssueCode(rawValue: "too_few")
    /// A collection with more elements than its count constraint allows.
    public static let tooMany = IssueCode(rawValue: "too_many")
    /// A string that does not match a ``Constraint/pattern(_:)``.
    public static let patternMismatch = IssueCode(rawValue: "pattern_mismatch")
    /// A value outside the allowed set of a ``Constraint/oneOf(_:)``, or a
    /// string that names no case of an enumeration.
    public static let notOneOf = IssueCode(rawValue: "not_one_of")
    /// A number that is not a multiple of the required step.
    public static let notMultiple = IssueCode(rawValue: "not_multiple")
    /// An element that repeats an earlier one in an array that must have
    /// unique elements.
    public static let notUnique = IssueCode(rawValue: "not_unique")
    /// An integer that a `Double` cannot hold exactly (above 2^53), which
    /// would be silently rounded rather than rejected by most readers.
    public static let precisionLoss = IssueCode(rawValue: "precision_loss")
    /// A number that is not a finite `Double`: it overflows, or (for a
    /// value built in Swift) it is NaN or infinite.
    public static let notFinite = IssueCode(rawValue: "not_finite")
    /// A ``Constraint/custom(id:description:check:)`` that rejected the
    /// value. The constraint's id and description are in the parameters.
    public static let custom = IssueCode(rawValue: "custom")

    /// The value has the right shape but a conversion written in code
    /// refused it: a timestamp that is not a date, a URL with no host. The
    /// reason is in the `message` parameter.
    public static let invalidValue = IssueCode(rawValue: "invalid_value")

    /// A string that does not follow the format its schema reads: a
    /// date-time that is not RFC 3339, a URL that does not parse, a UUID
    /// with a digit missing, text that is not base64, a decimal written
    /// with a comma. The format is in the `format` parameter and what is
    /// wrong with this value, when it can be said, in `message`.
    public static let invalidFormat = IssueCode(rawValue: "invalid_format")

    // MARK: Wire tolerance

    /// A warning: a value that names no case of an enumeration that has a
    /// case for unknown values, which it was read as. A server that adds a
    /// case does not break an older client; the client is told.
    public static let unknownCase = IssueCode(rawValue: "unknown_case")
    /// A warning: an element of a lossy array that did not decode and was
    /// left out. Its `index` and the first problem with it are in the
    /// parameters.
    public static let droppedElement = IssueCode(rawValue: "dropped_element")

    // MARK: Versions

    /// A document of a version newer than the schema's, which the schema
    /// cannot read without losing what the newer release wrote. An error
    /// unless the schema preserves unknown keys, when it is a warning and
    /// the newer fields are carried along.
    public static let versionTooNew = IssueCode(rawValue: "version_too_new")
    /// A document of a version no migration reads: older than the oldest
    /// the schema keeps a path from, or in a gap in the history.
    public static let versionUnsupported = IssueCode(rawValue: "version_unsupported")
    /// A document was migrated from an older version before it was read.
    /// A warning, one per step, with `from` and `to` in the parameters.
    public static let migrated = IssueCode(rawValue: "migrated")
    /// A migration step could not be applied to this document.
    public static let migrationFailed = IssueCode(rawValue: "migration_failed")

    // MARK: Input and declarations

    /// The input is not well-formed JSON. The parser's own code, message and
    /// location are in the parameters and the issue's source range.
    public static let parseError = IssueCode(rawValue: "parse_error")
    /// The schema itself is wrong: a pattern that is not a regular
    /// expression, a `multipleOf` of zero. Reported as an issue rather than
    /// a crash because the schema is code, and code that fails at runtime
    /// should fail where the failure can be read.
    public static let invalidConstraint = IssueCode(rawValue: "invalid_constraint")
    /// A decode stopped recording issues because it reached
    /// ``DecodeOptions/maxIssues``. The value was still rejected correctly.
    public static let tooManyIssues = IssueCode(rawValue: "too_many_issues")

    public var description: String { rawValue }
}
