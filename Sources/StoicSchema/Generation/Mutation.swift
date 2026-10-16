public import StoicJSON

/// A problem a mutation is expected to cause, and where.
public struct ExpectedIssue: Sendable, Hashable, CustomStringConvertible {
    public var path: JSONPath
    public var code: IssueCode
    public var severity: Issue.Severity
    /// For a misspelt key or tag: the spelling the issue should suggest.
    public var suggestion: String?

    public init(path: JSONPath, code: IssueCode, severity: Issue.Severity = .error, suggestion: String? = nil) {
        self.path = path
        self.code = code
        self.severity = severity
        self.suggestion = suggestion
    }

    public var description: String { "\(path) \(code)" }
}

/// A valid document with one minimal violation, and the issue that violation
/// must cause.
///
/// This is the other half of a property test. Valid documents show that the
/// decoder accepts what it should; mutations show that it refuses what it
/// should, with the right code, at the right path, and nothing else. N
/// independent mutations must yield exactly N issues, which is what checks
/// the decoder accumulates rather than stops.
public struct Mutation: Sendable {
    /// What was done to the document.
    public enum Kind: String, Sendable, CaseIterable {
        case belowLowerBound
        case aboveUpperBound
        case wrongType
        case nullForNonNullable
        case missingRequiredKey
        case unknownKey
        case typoKey
        case tooLong
        case tooShort
        case tooMany
        case tooFew
        case notUnique
        case notMultiple
        case patternMismatch
        case badEnumValue
        case badUnionTag
        case typoUnionTag
        case missingDiscriminator
        case precisionLoss
        /// An integer written with a fraction (`5.0`): the same number, and
        /// a spelling `.strict` refuses for an integer field.
        case integralFraction
        case futureVersion
        /// A value of the right kind that a conversion refuses: a date that
        /// does not exist, a string that is not a URL (a transform's
        /// ``TransformNode/counterexamples``).
        case refusedByConversion
    }

    public var kind: Kind
    /// The mutated document.
    public var document: JSONValue
    /// The issues it must cause, and only these. Errors and warnings alike.
    public var expected: [ExpectedIssue]
    /// What was done, in a sentence, for a failure report.
    public var summary: String
    /// The part of the document the mutation changed. Two mutations whose
    /// locations are not nested in one another are independent.
    public var location: JSONPath
    /// Whether the decoder tolerates the violation (a bad element of a lossy
    /// array is dropped with a warning) although the exported JSON Schema,
    /// which has no such tolerance, rejects the document.
    public var isTolerated = false

    /// Makes the change to another document that has the same shape.
    let edit: @Sendable (JSONValue) -> JSONValue?
}

// MARK: - Editing JSON by path

extension JSONValue {
    /// A copy with the value at `path` changed by `body`, or `nil` if the
    /// path is not in the document.
    func editing(_ path: JSONPath, _ body: (inout JSONValue) -> Void) -> JSONValue? {
        var copy = self
        guard copy.edit(path.components[...], body) else { return nil }
        return copy
    }

    private mutating func edit(_ path: ArraySlice<JSONPath.Component>, _ body: (inout JSONValue) -> Void) -> Bool {
        guard let first = path.first else {
            body(&self)
            return true
        }
        switch (first, self) {
        case (.key(let key), .object(var object)):
            guard var child = object[key], child.edit(path.dropFirst(), body) else { return false }
            object[key] = child
            self = .object(object)
            return true
        case (.index(let index), .array(var array)):
            guard array.indices.contains(index), array[index].edit(path.dropFirst(), body) else { return false }
            self = .array(array)
            return true
        default:
            return false
        }
    }

    func replacing(_ path: JSONPath, with value: JSONValue) -> JSONValue? {
        editing(path) { $0 = value }
    }

    /// A copy with `key` added to, or changed in, the object at `path`.
    func setting(_ key: String, to value: JSONValue, inObjectAt path: JSONPath) -> JSONValue? {
        editing(path) { target in
            guard case .object(var object) = target else { return }
            object[key] = value
            target = .object(object)
        }
    }

    func removing(_ key: String, fromObjectAt path: JSONPath) -> JSONValue? {
        editing(path) { target in
            guard case .object(var object) = target else { return }
            object[key] = nil
            target = .object(object)
        }
    }

    /// A copy with the member `old` of the object at `path` spelt `new`,
    /// keeping its place.
    func renaming(_ old: String, to new: String, inObjectAt path: JSONPath) -> JSONValue? {
        editing(path) { target in
            guard case .object(let object) = target else { return }
            target = .object(
                JSONObject(
                    object.map { member in
                        member.key.utf8.elementsEqual(old.utf8) ? JSONObject.Member(key: new, value: member.value) : member
                    }))
        }
    }
}

extension JSONPath {
    /// Whether this path is `other` or lies below it, or the reverse.
    func overlaps(_ other: JSONPath) -> Bool {
        let count = Swift.min(components.count, other.components.count)
        return components.prefix(count).elementsEqual(other.components.prefix(count))
    }
}
