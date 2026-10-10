internal import StoicJSON

/// Everything one decode carries from node to node: where it is, what it has
/// found, and the knobs it was started with.
///
/// Decoders take it `inout` rather than returning issues, which is what lets
/// a decode accumulate: a field that fails records its issues and returns
/// `nil`, and the object around it carries on to the next field.
struct DecodeState {
    let options: DecodeOptions
    /// The parsed text, when the input was text, for source ranges.
    let document: JSONDocument?

    /// Where the decode is, in the schema's spelling of keys.
    var path = JSONPath()
    /// Where the decode is, in the input's spelling, for looking up source
    /// ranges. It differs from `path` only below a field read through an
    /// alias.
    var inputPath = JSONPath()

    var issues: [Issue] = []
    /// Errors raised, including any too numerous to record.
    var errorCount = 0
    private var truncated = false

    /// The input path of an object that was migrated, while it is being
    /// decoded. A migration rewrites the object, so the text no longer
    /// shows what the issues are about; they point at the whole object
    /// instead of at a place that may now mean something else.
    var migratedRegion: JSONPath?

    /// Above zero while inside a secret field.
    var secretDepth = 0

    var checker = ConstraintChecker()

    init(options: DecodeOptions, document: JSONDocument? = nil) {
        self.options = options
        self.document = document
    }

    var isLenient: Bool { options.mode == .lenient }

    // MARK: Position

    mutating func push(key: String, spelledAs input: String? = nil) {
        path.components.append(.key(key))
        inputPath.components.append(.key(input ?? key))
    }

    mutating func push(index: Int) {
        path.components.append(.index(index))
        inputPath.components.append(.index(index))
    }

    mutating func pop() {
        path.components.removeLast()
        inputPath.components.removeLast()
    }

    // MARK: Reporting

    enum Target {
        /// The value at the path.
        case value
        /// The key that names the value at the path.
        case key
    }

    /// Records an issue at the current position (or at `path`, for a child
    /// that does not exist). Anything derived from the input's value is
    /// dropped inside a secret field.
    mutating func report(
        _ code: IssueCode,
        severity: Issue.Severity = .error,
        path explicitPath: JSONPath? = nil,
        sourcePath explicitSourcePath: JSONPath? = nil,
        target: Target = .value,
        parameters: JSONObject = JSONObject(),
        expected: String? = nil,
        actual: String? = nil,
        suggestions: [String] = [],
        suggestionsAreFromInput: Bool = true
    ) {
        if severity == .error { errorCount += 1 }
        if issues.count >= options.maxIssues {
            if !truncated {
                truncated = true
                issues.append(
                    Issue(
                        severity: .warning, code: .tooManyIssues,
                        parameters: ["limit": .number(JSONNumber(options.maxIssues))]))
            }
            return
        }
        let redacted = secretDepth > 0
        issues.append(
            Issue(
                severity: severity,
                path: explicitPath ?? path,
                code: code,
                parameters: parameters,
                expected: expected,
                actual: redacted ? nil : actual,
                suggestions: redacted && suggestionsAreFromInput ? [] : suggestions,
                source: source(at: explicitSourcePath ?? inputPath, target: target)))
    }

    /// Records the problems a constraint list finds in `value`, which sits
    /// at the current position. Returns whether there were none.
    mutating func apply(_ constraints: [Constraint], to value: JSONValue) -> Bool {
        guard !constraints.isEmpty else { return true }
        let violations = checker.violations(of: constraints, in: value)
        for violation in violations {
            report(
                violation.code,
                path: JSONPath(path.components + violation.relativePath.components),
                sourcePath: JSONPath(inputPath.components + violation.relativePath.components),
                parameters: violation.parameters, expected: violation.expected, actual: violation.actual,
                suggestions: [])
        }
        return violations.isEmpty
    }

    /// The text at `path`, or the nearest enclosing text that exists: a
    /// missing key has no range of its own, but the object that lacks it
    /// does.
    private func source(at path: JSONPath, target: Target) -> SourceRange? {
        guard let document else { return nil }
        if let region = migratedRegion { return document.range(of: region) }
        var current = path
        if target == .key, let range = document.keyRange(of: current) { return range }
        while true {
            if let range = document.range(of: current) { return range }
            guard let parent = current.parent else { return nil }
            current = parent
        }
    }

    // MARK: Type mismatches

    /// A value of the wrong kind. `hints` are spellings that would have
    /// been right, shown as "did you mean".
    mutating func typeMismatch(expected: String, found json: JSONValue, hints: [String] = []) {
        let actual: String?
        switch json {
        case .string, .number, .bool: actual = json.briefDescription
        case .null, .array, .object: actual = nil
        }
        report(
            .typeMismatch, parameters: ["found": .string(json.kindName)], expected: expected, actual: actual,
            suggestions: hints)
    }

    // MARK: Leniency

    /// Turns the errors recorded since `mark` into repairs, because the
    /// field they belong to is being replaced by its default.
    mutating func repair(since mark: Int, errorsBefore: Int, using replacement: String?) {
        var index = mark
        while index < issues.count {
            if issues[index].severity == .error {
                issues[index].severity = .repaired
                if let replacement {
                    issues[index].parameters["repair"] = .string("used the default \(replacement)")
                } else {
                    issues[index].parameters["repair"] = .string("used the default")
                }
            }
            index += 1
        }
        errorCount = errorsBefore
    }
}

/// What an encode carries: how to write, and what could not be written.
struct EncodeState {
    var style: EncodeStyle
    var path = JSONPath()
    /// Values the schema could not represent (a NaN where JSON has no NaN).
    var problems: [Issue] = []

    init(style: EncodeStyle) {
        self.style = style
    }

    mutating func push(key: String) { path.components.append(.key(key)) }
    mutating func push(index: Int) { path.components.append(.index(index)) }
    mutating func pop() { path.components.removeLast() }

    mutating func notFinite(_ value: Double) {
        problems.append(
            Issue(
                path: path, code: .notFinite, expected: "a finite number",
                actual: value.isNaN ? "NaN" : (value < 0 ? "-infinity" : "infinity")))
    }
}
