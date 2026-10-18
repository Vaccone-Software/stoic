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

    /// What was found, in the order found. Their ``Issue/source`` is filled
    /// in by ``resolvedIssues()`` at the end, from `offsets`.
    private(set) var issues: [Issue] = []
    /// Where in the text each issue is, as bytes, parallel to `issues`.
    ///
    /// Detecting a problem and explaining it are kept apart: a line and
    /// column cost a walk along the line, and a minified document is one
    /// line, so computing them as each issue is found made a thousand issues
    /// at the end of a megabyte cost a thousand megabyte walks. Offsets are
    /// a path walk; the lines and columns of all of them are found at the
    /// end in one pass.
    private var offsets: [Range<Int>?] = []
    /// Errors raised, including any too numerous to record.
    var errorCount = 0
    private var truncated = false

    /// The input path of an object that was migrated, while it is being
    /// decoded. A migration rewrites the object, so the text no longer
    /// shows what the issues are about; they point at the whole object
    /// instead of at a place that may now mean something else.
    var migratedRegion: JSONPath?

    /// Values a normalization moved, oldest first, each with the input path
    /// of the object it ran on. A moved value is found in the text where it
    /// was written, not where the normalization put it: an issue about
    /// `$.searcher` points at the `hyper` the file says.
    var relocations: [(base: JSONPath, move: Relocation)] = []

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
    ///
    /// `suggestions` is evaluated only if the issue is recorded: past
    /// `maxIssues` an issue is counted, not explained, and a did-you-mean is
    /// the expensive part of an explanation (an edit distance per candidate),
    /// so a document of a hundred thousand misspelt keys costs a hundred
    /// thousand lookups, not a hundred thousand searches.
    mutating func report(
        _ code: IssueCode,
        severity: Issue.Severity = .error,
        path explicitPath: JSONPath? = nil,
        sourcePath explicitSourcePath: JSONPath? = nil,
        target: Target = .value,
        parameters: JSONObject = JSONObject(),
        expected: String? = nil,
        actual: String? = nil,
        suggestions: @autoclosure () -> [String] = [],
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
                offsets.append(nil)
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
                suggestions: redacted && suggestionsAreFromInput ? [] : suggestions()))
        offsets.append(offsets(at: explicitSourcePath ?? inputPath, target: target))
    }

    /// The issues, each with its line and column when the input was text,
    /// all found in one pass over the text.
    func resolvedIssues() -> [Issue] {
        guard let document else { return issues }
        var positioned: [Int] = []
        var ranges: [Range<Int>] = []
        for (index, offsets) in offsets.enumerated() {
            guard let offsets else { continue }
            positioned.append(index)
            ranges.append(offsets)
        }
        var resolved = issues
        for (index, range) in zip(positioned, document.ranges(ofOffsets: ranges)) {
            resolved[index].source = range
        }
        return resolved
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
                suggestions: violation.suggestions)
        }
        return violations.isEmpty
    }

    /// Whether `constraints`, which `input` satisfied, also hold for
    /// `received`: the JSON of the value a conversion made from `input`.
    /// Records `precision_loss` if not.
    ///
    /// Constraints are checked on what was sent, and a conversion can change
    /// it: `9.99999999999999999999` satisfies `.lessThan(10)` and is the
    /// `Double` `10.0`, which does not. The caller is handed the converted
    /// value, so it is the one that must be valid; a `Refined` built from it
    /// must be one its own initialiser would accept.
    mutating func received(_ received: JSONValue, from input: JSONValue, keeps constraints: [Constraint]) -> Bool {
        guard !constraints.isEmpty, received != input else { return true }
        guard let broken = checker.violations(of: constraints, in: received).first else { return true }
        var parameters: JSONObject = ["constraint": .string(broken.expected)]
        if secretDepth == 0 { parameters["received"] = received }
        report(.precisionLoss, parameters: parameters, expected: broken.expected, actual: input.briefDescription)
        return false
    }

    /// The bytes of the text at `path`, or of the nearest enclosing text that
    /// exists: a missing key has no range of its own, but the object that
    /// lacks it does.
    private func offsets(at path: JSONPath, target: Target) -> Range<Int>? {
        guard let document else { return nil }
        if let region = migratedRegion { return document.offsets(of: region) }
        var current = original(of: path)
        if target == .key, let range = document.keyOffsets(of: current) { return range }
        while true {
            if let range = document.offsets(of: current) { return range }
            guard let parent = current.parent else { return nil }
            current = parent
        }
    }

    /// `path` as the text has it: each normalization that ran, latest first,
    /// has its moves undone, so a path in the normalized document leads to
    /// the place its value was written.
    private func original(of path: JSONPath) -> JSONPath {
        var current = path
        for (base, move) in relocations.reversed() {
            let target = base.components + move.to.map { JSONPath.Component.key($0) }
            guard current.components.starts(with: target) else { continue }
            let rest = current.components.dropFirst(target.count)
            current = JSONPath(base.components + move.from.map { .key($0) } + rest)
        }
        return current
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

extension DecodeState {
    /// Replaces what was recorded for an element, from `mark` on, with one
    /// warning that the element at `index` was dropped. The reason is the
    /// first error it caused, in words.
    mutating func dropElement(at index: Int, since mark: Int, errorsBefore: Int) {
        let reason = issues[mark...].first { $0.severity == .error }?.message
        issues.removeSubrange(mark...)
        offsets.removeSubrange(mark...)
        errorCount = errorsBefore
        var parameters: JSONObject = ["index": .number(JSONNumber(index))]
        if let reason { parameters["reason"] = .string(reason) }
        report(.droppedElement, severity: .warning, parameters: parameters)
    }
}

extension DecodeState {
    /// Replaces what was recorded for a dictionary entry, from `mark` on, with
    /// one warning that the entry under `key` was dropped. The reason is the
    /// first error it caused, in words. Called with the path at the entry.
    mutating func dropEntry(key: String, since mark: Int, errorsBefore: Int) {
        let reason = issues[mark...].first { $0.severity == .error }?.message
        issues.removeSubrange(mark...)
        offsets.removeSubrange(mark...)
        errorCount = errorsBefore
        var parameters: JSONObject = ["key": .string(key)]
        if let reason { parameters["reason"] = .string(reason) }
        report(.droppedEntry, severity: .warning, parameters: parameters)
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
