public import StoicJSON

/// One problem found while checking a value against a schema, with enough
/// structure for a program to react to it and enough prose for a person.
///
/// The fields answer, in order: how bad is it (``severity``), where is it
/// (``path``, and ``source`` when the input was text), what kind of problem
/// is it (``code``), what was wanted (``expected``) and found (``actual``),
/// and what the author probably meant (``suggestions``). ``message`` is
/// derived from those, never stored, so wording stays in one place and a
/// localised front end can build its own from `code` and ``parameters``.
///
/// ``actual`` is the one field that can leak. It is never filled for a
/// secret field, and nothing else here is derived from the secret's value
/// (suggestions that come from comparing the input are dropped too), so an
/// issue can be logged or shown without a second look.
public struct Issue: Sendable, Hashable, CustomStringConvertible {
    /// How much an issue matters.
    public enum Severity: Sendable, Hashable, CaseIterable, CustomStringConvertible {
        /// The value is invalid. A decode with an error produces no value.
        case error
        /// The value was invalid and has been replaced, under
        /// ``DecodeOptions/Mode-swift.enum/lenient``: the field's default
        /// was used, or an unknown key was ignored. The decode succeeded;
        /// the user should still be told.
        case repaired
        /// Accepted, but worth saying: an unknown key under `.warn`, a
        /// deprecated spelling, a number written `1.0` read as an integer.
        case warning

        public var description: String {
            switch self {
            case .error: "error"
            case .repaired: "repaired"
            case .warning: "warning"
            }
        }
    }

    public var severity: Severity

    /// Where the problem is, in the schema's own spelling of keys (so
    /// `$.scrollSpeed` even if the file said `scroll_speed`). Renders as
    /// `$.network.hosts[3]`.
    public var path: JSONPath

    /// What kind of problem. Stable; see ``IssueCode``.
    public var code: IssueCode

    /// The facts the message is built from: bounds, counts, the key that was
    /// missing. Machine-readable, so a UI can say "at most 8" without
    /// parsing a sentence.
    public var parameters: JSONObject

    /// What would have been accepted, as a phrase: `a number between 200
    /// and 4000`.
    public var expected: String?

    /// What was found, as JSON text, shortened if it is long. `nil` for a
    /// secret, and whenever showing the value would add nothing.
    public var actual: String?

    /// Likely intended values, best first, at most three: spellings of a
    /// key, cases of an enumeration, `10` for `"10"`. Deterministic.
    public var suggestions: [String]

    /// The first suggestion.
    public var suggestion: String? { suggestions.first }

    /// The text this issue is about, when the input was text. For a
    /// problem with a key (`unknown_key`) it is the key; for a missing
    /// value it is the object that lacks it.
    public var source: SourceRange?

    public init(
        severity: Severity = .error,
        path: JSONPath = .root,
        code: IssueCode,
        parameters: JSONObject = JSONObject(),
        expected: String? = nil,
        actual: String? = nil,
        suggestions: [String] = [],
        source: SourceRange? = nil
    ) {
        self.severity = severity
        self.path = path
        self.code = code
        self.parameters = parameters
        self.expected = expected
        self.actual = actual
        self.suggestions = suggestions
        self.source = source
    }

    // MARK: Message

    /// One sentence, derived from the code and the facts. It names the
    /// value only when ``actual`` is present.
    public var message: String {
        var text = baseMessage
        if severity == .repaired, let repair = parameters["repair"]?.string {
            text += "; " + repair
        }
        return text
    }

    private var baseMessage: String {
        let found = actual.map { " " + $0 } ?? ""
        let value = actual ?? "value"
        let want = expected ?? "a different value"
        switch code {
        case .typeMismatch:
            let kind = parameters["found"]?.string ?? "another kind of value"
            return "expected \(want), found \(kind)\(found)"
        case .missingKey:
            return "missing required key `\(parameters["key"]?.string ?? lastKey)`"
        case .unknownKey:
            return "unknown key `\(parameters["key"]?.string ?? lastKey)`"
        case .deprecatedKey:
            let key = parameters["key"]?.string ?? lastKey
            if let replacement = parameters["replacement"]?.string {
                return "`\(key)` is a deprecated spelling of `\(replacement)`"
            }
            if let reason = parameters["reason"]?.string, !reason.isEmpty {
                return "`\(key)` is deprecated: \(reason)"
            }
            return "`\(key)` is deprecated"
        case .duplicateKey:
            let key = parameters["key"]?.string ?? lastKey
            let other = parameters["other"]?.string ?? "another spelling"
            return "`\(key)` repeats `\(other)`, which names the same field"
        case .outOfRange:
            return "\(value) is out of range, expected \(want)"
        case .tooShort, .tooLong:
            let count = parameters["count"]?.number?.lexeme ?? "?"
            let unit = parameters["unit"]?.string ?? "characters"
            let how = code == .tooShort ? "short" : "long"
            return "too \(how): \(count) \(unit), expected \(want)"
        case .tooFew, .tooMany:
            let count = parameters["count"]?.number?.lexeme ?? "?"
            let how = code == .tooFew ? "few" : "many"
            return "too \(how) elements: \(count), expected \(want)"
        case .patternMismatch:
            return "\(value) does not match the pattern, expected \(want)"
        case .notOneOf:
            return "\(value) is not allowed, expected \(want)"
        case .notMultiple:
            return "\(value) is not \(want)"
        case .notUnique:
            let first = parameters["firstIndex"]?.number?.lexeme ?? "an earlier index"
            return "duplicates the element at index \(first)"
        case .precisionLoss:
            return "\(value) cannot be held exactly by a Double (integers above 2^53 lose digits)"
        case .notFinite:
            return "\(value) is not a finite Double"
        case .custom:
            let id = parameters["id"]?.string ?? "custom"
            let description = parameters["description"]?.string ?? want
            return "fails the `\(id)` check: \(description)"
        case .invalidValue:
            let reason = parameters["message"]?.string ?? "is not valid"
            guard let expected else { return reason }
            return "\(reason), expected \(expected)"
        case .parseError:
            return "invalid JSON: \(parameters["message"]?.string ?? "malformed input")"
        default:
            return parameters["message"]?.string ?? code.rawValue.replacing("_", with: " ")
        }
    }

    private var lastKey: String {
        if case .key(let key)? = path.components.last { return key }
        return "?"
    }

    // MARK: Description

    /// `line:col $.path: message (did you mean `x`?)`: the shape compilers
    /// print, so editors and terminals that link `file:line:col` work with
    /// it. The position is left out when the input was not text, and issues
    /// that are not errors say what they are after the path.
    public var description: String {
        var line = ""
        if let source { line += "\(source.start) " }
        line += "\(path):"
        if severity != .error { line += " \(severity):" }
        line += " " + message
        if !suggestions.isEmpty {
            let quoted = suggestions.map { "`\($0)`" }
            let list: String
            switch quoted.count {
            case 1: list = quoted[0]
            case 2: list = quoted[0] + " or " + quoted[1]
            default: list = quoted.dropLast().joined(separator: ", ") + ", or " + quoted[quoted.count - 1]
            }
            line += " (did you mean \(list)?)"
        }
        return line
    }
}

extension JSONObject {
    /// Builds parameters from ordered pairs, for issue construction.
    init(pairs: [(String, JSONValue)]) {
        self.init(pairs.map { JSONObject.Member(key: $0.0, value: $0.1) })
    }
}

/// The reason a value was refused: every issue found, in the order they were
/// found.
///
/// Thrown by the entry points that return a bare value. Warnings and
/// repairs that happened along the way are included, because an error in a
/// file is easier to fix with the deprecation notices next to it. ``errors``
/// filters to the ones that caused the refusal.
public struct ValidationFailure: Error, Sendable, Hashable, CustomStringConvertible {
    public var issues: [Issue]

    public init(issues: [Issue]) {
        self.issues = issues
    }

    public init(_ issue: Issue) {
        issues = [issue]
    }

    /// The issues with severity ``Issue/Severity-swift.enum/error``.
    public var errors: [Issue] {
        issues.filter { $0.severity == .error }
    }

    /// One issue per line, each in the form of ``Issue/description``.
    public var description: String {
        issues.map(\.description).joined(separator: "\n")
    }
}
