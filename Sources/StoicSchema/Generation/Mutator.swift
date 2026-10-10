internal import StoicJSON

/// Finds every minimal violation a valid document admits, by walking the
/// schema's node tree and the document together.
///
/// A violation is *minimal* when it breaks exactly one rule and nothing else
/// follows from it: a number one step past a bound, a string one scalar too
/// long, a key renamed by one edit. Each candidate is checked with the real
/// constraint interpreter before it is offered, so that "exactly one issue"
/// is a property of the mutation and not a hope. What the walk cannot make
/// minimal (a bound whose neighbour is also not a multiple of the step) it
/// leaves out.
struct Mutator {
    var maker: ValueMaker
    private var checker = ConstraintChecker()

    init(maker: ValueMaker) {
        self.maker = maker
    }

    private struct Context {
        var root: JSONValue
        /// When set, replaces the location of every mutation found below:
        /// the part of the document is one unit as far as independence goes.
        var unit: JSONPath?
        /// The node's generic mutations (null, wrong type) were already made
        /// by a wrapper around it.
        var genericDone = false
    }

    mutating func mutations(of document: JSONValue, node: SchemaNode) -> [Mutation] {
        var found: [Mutation] = []
        collect(node, document, .root, Context(root: document), &found)
        return found
    }

    // MARK: Construction

    private func make(
        _ kind: Mutation.Kind,
        _ context: Context,
        location: JSONPath,
        expected: [ExpectedIssue],
        summary: String,
        edit: @escaping @Sendable (JSONValue) -> JSONValue?
    ) -> Mutation? {
        guard let document = edit(context.root) else { return nil }
        return Mutation(
            kind: kind, document: document, expected: expected, summary: summary,
            location: context.unit ?? location, edit: edit)
    }

    private func replacement(
        _ kind: Mutation.Kind,
        _ context: Context,
        at path: JSONPath,
        with value: JSONValue,
        expect code: IssueCode,
        at issuePath: JSONPath? = nil,
        summary: String
    ) -> Mutation? {
        make(
            kind, context, location: path, expected: [ExpectedIssue(path: issuePath ?? path, code: code)],
            summary: summary + " at \(path)", edit: { $0.replacing(path, with: value) })
    }

    // MARK: The walk

    private mutating func collect(
        _ node: SchemaNode,
        _ value: JSONValue,
        _ path: JSONPath,
        _ context: Context,
        _ out: inout [Mutation]
    ) {
        var context = context
        if !context.genericDone {
            context.genericDone = true
            if !Self.acceptsNull(node), !value.isNull {
                out.add(replacement(
                        .nullForNonNullable, context, at: path, with: .null, expect: .typeMismatch,
                        summary: "replaced the value with null"))
            }
            if let wrong = Self.wrongValue(for: node) {
                out.add(replacement(
                        .wrongType, context, at: path, with: wrong, expect: .typeMismatch,
                        summary: "replaced the value with \(wrong.kindName) \(wrong.briefDescription)"))
            }
        }

        switch node {
        case .boolean, .enumeration, .json:
            if case .enumeration(_, let cases) = node, case .string(let current) = value {
                collectBadEnum(cases: cases, current: current, path, context, &out)
            }

        case .integerEnumeration(_, let cases):
            let taken = Set(cases.map(\.value))
            var bad = (cases.map(\.value).max() ?? 0) + 1
            while taken.contains(bad) { bad += 1 }
            out.add(replacement(
                    .badEnumValue, context, at: path, with: .number(JSONNumber(bad)), expect: .notOneOf,
                    summary: "replaced the value with \(bad), which is no case"))

        case .integer(let type, let constraints):
            collectInteger(type, constraints, value, path, context, &out)

        case .number(let constraints):
            collectNumber(constraints, value, path, context, &out)

        case .string(let constraints):
            collectString(constraints, value, path, context, &out)

        case .array(let element, let constraints):
            collectArray(element, constraints, value, path, context, &out)

        case .dictionary(let element, let constraints):
            collectDictionary(element, constraints, value, path, context, &out)

        case .optional(let wrapped, _):
            if !value.isNull { collect(wrapped, value, path, context, &out) }

        case .transformed(let transform):
            collect(transform.base, value, path, context, &out)
            for counterexample in transform.counterexamples where counterexample.value != value {
                out.add(replacement(
                        .refusedByConversion, context, at: path, with: counterexample.value, expect: counterexample.code,
                        summary: "replaced the value with \(counterexample.value.briefDescription), which \(transform.name) refuses"))
            }

        case .lazy(_, let resolve):
            collect(resolve(), value, path, context, &out)

        case .object(let object):
            collectObject(object, value, path, context, &out)

        case .union(let union):
            collectUnion(union, value, path, context, &out)
        }
    }

    // MARK: Generic

    /// Whether `null` is a valid value of the node.
    static func acceptsNull(_ node: SchemaNode) -> Bool {
        switch node {
        case .optional(_, let nullable): nullable
        case .json: true
        case .transformed(let transform): acceptsNull(transform.base)
        case .lazy(_, let resolve): acceptsNull(resolve())
        default: false
        }
    }

    /// A value of a kind the node refuses outright.
    static func wrongValue(for node: SchemaNode) -> JSONValue? {
        switch node {
        case .boolean: .number(JSONNumber(2))
        case .integer, .number: .string("abc")
        case .string: .number(JSONNumber(7))
        case .enumeration: .number(JSONNumber(3))
        case .integerEnumeration: .string("high")
        case .array, .object, .union: node.isObjectLike ? .array([]) : .object(JSONObject())
        case .dictionary: .array([])
        case .optional(let wrapped, _): wrongValue(for: wrapped)
        case .transformed(let transform): wrongValue(for: transform.base)
        case .lazy(_, let resolve): wrongValue(for: resolve())
        case .json: nil
        }
    }

    // MARK: Enumerations

    private mutating func collectBadEnum(
        cases: [String],
        current: String,
        _ path: JSONPath,
        _ context: Context,
        _ out: inout [Mutation]
    ) {
        let taken = Set(cases.map { ExactKey($0) })
        let candidates = [current.uppercased() + "!", current + "x", "zzz-not-a-case", ""]
        guard let bad = candidates.first(where: { !taken.contains(ExactKey($0)) }) else { return }
        out.add(replacement(
                .badEnumValue, context, at: path, with: .string(bad), expect: .notOneOf,
                summary: "replaced the value with \"\(bad)\", which is no case"))
    }

    // MARK: Integers

    private mutating func collectInteger(
        _ type: IntegerType,
        _ constraints: [Constraint],
        _ value: JSONValue,
        _ path: JSONPath,
        _ context: Context,
        _ out: inout [Mutation]
    ) {
        let (low, high) = ValueMaker.integerBounds(type, constraints)
        let typeLow = Int128(type.minimum.lexeme) ?? Int128(Int64.min)
        let typeHigh = Int128(type.maximum.lexeme) ?? Int128(Int64.max)
        var steps: [Int128] = [1, 2, 10, 100]
        for constraint in constraints {
            if case .multipleOf(let step) = constraint.kind, let whole = step.integralInt64, whole > 0 {
                steps.append(Int128(whole))
            }
        }

        /// Whether `candidate` breaks the range and nothing else.
        func breaksOnlyRange(_ candidate: Int128) -> Bool {
            if candidate < typeLow || candidate > typeHigh { return true }  // the type's own bound is checked first
            let found = checker.violations(of: constraints, in: .number(JSONNumber(candidate)))
            return found.count == 1 && found[0].code == .outOfRange
        }

        for step in steps {
            if breaksOnlyRange(low - step) {
                out.add(replacement(
                        .belowLowerBound, context, at: path, with: .number(JSONNumber(low - step)),
                        expect: .outOfRange, summary: "replaced the value with \(low - step), below its lower bound"))
                break
            }
        }
        for step in steps {
            if breaksOnlyRange(high + step) {
                out.add(replacement(
                        .aboveUpperBound, context, at: path, with: .number(JSONNumber(high + step)),
                        expect: .outOfRange, summary: "replaced the value with \(high + step), above its upper bound"))
                break
            }
        }
        out.add(replacement(
                .wrongType, context, at: path, with: .number(JSONNumber(lexeme: "1.5") ?? JSONNumber(1)),
                expect: .typeMismatch, summary: "replaced the integer with 1.5"))

        // A value inside the range that is not a multiple of the step.
        if case .number(let current) = value, let now = current.integralInt64.map({ Int128($0) }) {
            for constraint in constraints {
                guard case .multipleOf(let step) = constraint.kind, let whole = step.integralInt64, whole > 1 else {
                    continue
                }
                for offset in [Int128(1), -1, 2, -2] {
                    let candidate = now + offset
                    let found = checker.violations(of: constraints, in: .number(JSONNumber(candidate)))
                    if candidate >= low, candidate <= high, found.count == 1, found[0].code == .notMultiple {
                        out.add(replacement(
                                .notMultiple, context, at: path, with: .number(JSONNumber(candidate)),
                                expect: .notMultiple, summary: "replaced the value with \(candidate), not a multiple of \(whole)"))
                        break
                    }
                }
            }
        }
    }

    // MARK: Doubles

    private mutating func collectNumber(
        _ constraints: [Constraint],
        _ value: JSONValue,
        _ path: JSONPath,
        _ context: Context,
        _ out: inout [Mutation]
    ) {
        var lower: NumberBound?
        var upper: NumberBound?
        for constraint in constraints {
            if case .range(let range) = constraint.kind {
                if let bound = range.lower { lower = bound }
                if let bound = range.upper { upper = bound }
            }
        }
        func breaksOnlyRange(_ candidate: Double) -> JSONValue? {
            guard let number = JSONNumber(candidate) else { return nil }
            let found = checker.violations(of: constraints, in: .number(number))
            return found.count == 1 && found[0].code == .outOfRange ? .number(number) : nil
        }
        if let lower, let bound = lower.value.double {
            let candidates = lower.isInclusive ? [bound.nextDown, bound - 1, bound - 100] : [bound, bound.nextDown, bound - 1]
            var found: JSONValue?
            for candidate in candidates where found == nil { found = breaksOnlyRange(candidate) }
            if let bad = found {
                out.add(replacement(
                        .belowLowerBound, context, at: path, with: bad, expect: .outOfRange,
                        summary: "replaced the value with \(bad.briefDescription), below its lower bound"))
            }
        }
        if let upper, let bound = upper.value.double {
            let candidates = upper.isInclusive ? [bound.nextUp, bound + 1, bound + 100] : [bound, bound.nextUp, bound + 1]
            var found: JSONValue?
            for candidate in candidates where found == nil { found = breaksOnlyRange(candidate) }
            if let bad = found {
                out.add(replacement(
                        .aboveUpperBound, context, at: path, with: bad, expect: .outOfRange,
                        summary: "replaced the value with \(bad.briefDescription), above its upper bound"))
            }
        }
        // An integer a Double cannot hold exactly, and a number it cannot hold at all.
        if let loss = JSONNumber(lexeme: "9007199254740993") {
            out.add(replacement(
                    .precisionLoss, context, at: path, with: .number(loss), expect: .precisionLoss,
                    summary: "replaced the value with 2^53 + 1"))
        }
        if let huge = JSONNumber(lexeme: "1e400") {
            out.add(replacement(
                    .notFinite, context, at: path, with: .number(huge), expect: .notFinite,
                    summary: "replaced the value with 1e400"))
        }
    }

    // MARK: Strings

    private mutating func collectString(
        _ constraints: [Constraint],
        _ value: JSONValue,
        _ path: JSONPath,
        _ context: Context,
        _ out: inout [Mutation]
    ) {
        func only(_ code: IssueCode, _ candidate: String) -> Bool {
            let found = checker.violations(of: constraints, in: .string(candidate))
            return found.count == 1 && found[0].code == code
        }
        var lengthLimit: Int?
        var lengthFloor: Int?
        var allowed: [JSONValue]?
        var hasPattern = false
        for constraint in constraints {
            switch constraint.kind {
            case .length(let range, _):
                if let upper = range.upper { lengthLimit = Swift.min(lengthLimit ?? upper, upper) }
                if let lower = range.lower, lower > 0 { lengthFloor = Swift.max(lengthFloor ?? lower, lower) }
            case .oneOf(let values): allowed = values
            case .pattern: hasPattern = true
            default: break
            }
        }
        let ascii: (Int) -> String = { String(repeating: "a", count: $0) }
        if let limit = lengthLimit, limit < 10_000, only(.tooLong, ascii(limit + 1)) {
            out.add(replacement(
                    .tooLong, context, at: path, with: .string(ascii(limit + 1)), expect: .tooLong,
                    summary: "replaced the string with one of \(limit + 1) characters"))
        }
        if let floor = lengthFloor, floor < 10_000, only(.tooShort, ascii(floor - 1)) {
            out.add(replacement(
                    .tooShort, context, at: path, with: .string(ascii(floor - 1)), expect: .tooShort,
                    summary: "replaced the string with one of \(floor - 1) characters"))
        }
        if hasPattern {
            let lengths = [Swift.max(1, lengthFloor ?? 1), Swift.max(2, lengthFloor ?? 2), 3, 8]
            outer: for filler in ["\u{1}", "~", "!", "#", "\u{3A9}", "\u{1F600}", " "] {
                for length in lengths where only(.patternMismatch, String(repeating: filler, count: length)) {
                    let bad = String(repeating: filler, count: length)
                    out.add(replacement(
                            .patternMismatch, context, at: path, with: .string(bad), expect: .patternMismatch,
                            summary: "replaced the string with one that matches no pattern"))
                    break outer
                }
            }
        }
        if let allowed, !hasPattern {
            let taken = allowed.compactMap(\.string).map { ExactKey($0) }
            for filler in ["zzz-not-allowed", "?", "a"] where !taken.contains(ExactKey(filler)) {
                if only(.notOneOf, filler) {
                    out.add(replacement(
                            .badEnumValue, context, at: path, with: .string(filler), expect: .notOneOf,
                            summary: "replaced the string with one that is not allowed"))
                    break
                }
            }
        }
    }

    // MARK: Collections

    private func countLimits(_ constraints: [Constraint]) -> (low: Int?, high: Int?) {
        var low: Int?
        var high: Int?
        for constraint in constraints {
            guard case .count(let range) = constraint.kind else { continue }
            if let lower = range.lower, lower > 0 { low = Swift.max(low ?? lower, lower) }
            if let upper = range.upper { high = Swift.min(high ?? upper, upper) }
        }
        return (low, high)
    }

    private mutating func collectArray(
        _ element: SchemaNode,
        _ constraints: [Constraint],
        _ value: JSONValue,
        _ path: JSONPath,
        _ context: Context,
        _ out: inout [Mutation]
    ) {
        guard case .array(let items) = value else { return }
        let unique = constraints.contains { $0.kind == .unique }
        let (low, high) = countLimits(constraints)

        if let high, high < 64 {
            var longer = items
            var attempts = 0
            while longer.count < high + 1 && attempts < 200 {
                attempts += 1
                guard let fresh = try? maker.makePresent(element, depth: 0, path: path.appending(index: longer.count))
                else { break }
                if unique && longer.contains(fresh) { continue }
                longer.append(fresh)
            }
            if longer.count == high + 1 {
                let found = checker.violations(of: constraints, in: .array(longer))
                if found.count == 1, found[0].code == .tooMany {
                    out.add(replacement(
                            .tooMany, context, at: path, with: .array(longer), expect: .tooMany,
                            summary: "grew the array to \(high + 1) elements"))
                }
            }
        }
        if let low, items.count >= low {
            let shorter = Array(items.prefix(low - 1))
            let found = checker.violations(of: constraints, in: .array(shorter))
            if found.count == 1, found[0].code == .tooFew {
                out.add(replacement(
                        .tooFew, context, at: path, with: .array(shorter), expect: .tooFew,
                        summary: "cut the array to \(low - 1) elements"))
            }
        }
        if unique, let first = items.first {
            var repeated = items
            var duplicateIndex = 1
            if items.count >= 2 {
                repeated[1] = first
            } else {
                repeated.append(first)
            }
            duplicateIndex = 1
            let found = checker.violations(of: constraints, in: .array(repeated))
            if found.count == 1, found[0].code == .notUnique {
                out.add(replacement(
                        .notUnique, context, at: path, with: .array(repeated), expect: .notUnique,
                        at: path.appending(index: duplicateIndex), summary: "repeated the first element"))
            }
        }

        // Elements. Where uniqueness ties them together, one mutation of an
        // element could duplicate another, so the array is a unit.
        var inner = context
        inner.genericDone = false
        if unique { inner.unit = context.unit ?? path }
        for (index, item) in items.enumerated().prefix(3) {
            collect(element, item, path.appending(index: index), inner, &out)
        }
    }

    private mutating func collectDictionary(
        _ element: SchemaNode,
        _ constraints: [Constraint],
        _ value: JSONValue,
        _ path: JSONPath,
        _ context: Context,
        _ out: inout [Mutation]
    ) {
        guard case .object(let entries) = value else { return }
        let (low, high) = countLimits(constraints)
        if let high, high < 64 {
            var longer = entries
            var attempts = 0
            while longer.count < high + 1 && attempts < 200 {
                attempts += 1
                let key = "k" + String(attempts)
                guard longer[key] == nil,
                    let fresh = try? maker.makePresent(element, depth: 0, path: path.appending(key: key))
                else { continue }
                longer[key] = fresh
            }
            if longer.count == high + 1 {
                let found = checker.violations(of: constraints, in: .object(longer))
                if found.count == 1, found[0].code == .tooMany {
                    out.add(replacement(
                            .tooMany, context, at: path, with: .object(longer), expect: .tooMany,
                            summary: "grew the dictionary to \(high + 1) entries"))
                }
            }
        }
        if let low, entries.count >= low {
            let shorter = JSONObject(entries.prefix(low - 1))
            let found = checker.violations(of: constraints, in: .object(shorter))
            if found.count == 1, found[0].code == .tooFew {
                out.add(replacement(
                        .tooFew, context, at: path, with: .object(shorter), expect: .tooFew,
                        summary: "cut the dictionary to \(low - 1) entries"))
            }
        }
        var inner = context
        inner.genericDone = false
        for member in entries.prefix(3) {
            collect(element, member.value, path.appending(key: member.key), inner, &out)
        }
    }

    // MARK: Objects

    private mutating func collectObject(
        _ object: ObjectNode,
        _ value: JSONValue,
        _ path: JSONPath,
        _ context: Context,
        _ out: inout [Mutation]
    ) {
        guard case .object(let members) = value else { return }
        let names = object.fields.flatMap { [$0.key] + $0.aliases }
        let reserved = object.versioning?.key
        var inner = context
        inner.genericDone = false

        for field in object.fields {
            let fieldPath = path.appending(key: field.key)
            guard let present = members[field.key] else { continue }
            if field.isRequired {
                out.add(make(
                        .missingRequiredKey, context, location: fieldPath,
                        expected: [ExpectedIssue(path: fieldPath, code: .missingKey)],
                        summary: "removed the required key \(fieldPath)",
                        edit: { [path] in $0.removing(field.key, fromObjectAt: path) }))
            }
            collect(field.node, present, fieldPath, inner, &out)

            if object.unknownKeys == .reject || object.unknownKeys == .warn,
                let typo = Self.typo(of: field.key, avoiding: names + members.keys + (reserved.map { [$0] } ?? [])),
                Suggestions.nearest(to: typo, among: names).contains(field.key)
            {
                let severity: Issue.Severity = object.unknownKeys == .warn ? .warning : .error
                let typoPath = path.appending(key: typo)
                // A field that must be present stays; the misspelling is an extra.
                let keepOriginal = field.isRequired
                out.add(make(
                        .typoKey, context, location: keepOriginal ? typoPath : fieldPath,
                        expected: [ExpectedIssue(path: typoPath, code: .unknownKey, severity: severity, suggestion: field.key)],
                        summary: "misspelt the key \(field.key) as \(typo)",
                        edit: { [path] in
                            keepOriginal
                                ? $0.setting(typo, to: present, inObjectAt: path)
                                : $0.renaming(field.key, to: typo, inObjectAt: path)
                        }))
            }
        }

        if object.unknownKeys == .reject || object.unknownKeys == .warn {
            let key = "zzUnknownKey"
            if members[key] == nil {
                let severity: Issue.Severity = object.unknownKeys == .warn ? .warning : .error
                let keyPath = path.appending(key: key)
                out.add(make(
                        .unknownKey, context, location: keyPath,
                        expected: [ExpectedIssue(path: keyPath, code: .unknownKey, severity: severity)],
                        summary: "added the unknown key \(key) at \(path)",
                        edit: { [path] in $0.setting(key, to: .number(JSONNumber(1)), inObjectAt: path) }))
            }
        }

        if let versioning = object.versioning, object.unknownKeys != .preserve {
            let versionPath = path.appending(key: versioning.key)
            out.add(make(
                    .futureVersion, context, location: path,
                    expected: [ExpectedIssue(path: versionPath, code: .versionTooNew)],
                    summary: "raised the version to \(versioning.current + 1)",
                    edit: { [path] in
                        $0.setting(versioning.key, to: .number(JSONNumber(versioning.current + 1)), inObjectAt: path)
                    }))
        }
    }

    /// `key` with one slip: two letters swapped, one dropped, one replaced.
    /// Nil if no slip leaves a spelling that is not already taken, or if the
    /// key is too short for anyone to call the result a typo.
    static func typo(of key: String, avoiding taken: [String]) -> String? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count >= 4 else { return nil }
        let takenNormalized = Set(taken.map { Suggestions.normalized($0) })
        var candidates: [[Unicode.Scalar]] = []
        // Swap the two letters in the middle: the commonest slip.
        for index in stride(from: scalars.count / 2, to: scalars.count - 1, by: 1) where scalars[index] != scalars[index + 1] {
            var swapped = scalars
            swapped.swapAt(index, index + 1)
            candidates.append(swapped)
            break
        }
        candidates.append(Array(scalars[..<(scalars.count - 1)]))  // drop the last letter
        var dropped = scalars
        dropped.remove(at: scalars.count / 2)
        candidates.append(dropped)
        var replaced = scalars
        replaced[scalars.count / 2] = replaced[scalars.count / 2] == "q" ? "z" : "q"
        candidates.append(replaced)
        for candidate in candidates {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: candidate)
            let text = String(view)
            if !takenNormalized.contains(Suggestions.normalized(text)) { return text }
        }
        return nil
    }

    // MARK: Unions

    private mutating func collectUnion(
        _ union: UnionNode,
        _ value: JSONValue,
        _ path: JSONPath,
        _ context: Context,
        _ out: inout [Mutation]
    ) {
        guard case .object(let members) = value, case .string(let tag)? = members[union.discriminator],
            let entry = union.cases.first(where: { ExactKey($0.tag) == ExactKey(tag) })
        else { return }
        let tagPath = path.appending(key: union.discriminator)
        // What follows from a bad discriminator is that the payload cannot
        // be read, so the whole union is one unit.
        let whole = Context(root: context.root, unit: context.unit ?? path, genericDone: true)

        out.add(replacement(
                .badUnionTag, whole, at: tagPath, with: .string("zzz-not-a-tag"), expect: .notOneOf,
                summary: "replaced the tag with one that names no case"))
        if let typo = Self.typo(of: tag, avoiding: union.tags),
            Suggestions.nearest(to: typo, among: union.tags).contains(tag)
        {
            out.add(make(
                    .typoUnionTag, whole, location: tagPath,
                    expected: [ExpectedIssue(path: tagPath, code: .notOneOf, suggestion: tag)],
                    summary: "misspelt the tag \(tag) as \(typo)",
                    edit: { $0.replacing(tagPath, with: .string(typo)) }))
        }
        out.add(make(
                .missingDiscriminator, whole, location: tagPath,
                expected: [ExpectedIssue(path: tagPath, code: .missingKey)],
                summary: "removed the discriminator \(union.discriminator)",
                edit: { [path] in $0.removing(union.discriminator, fromObjectAt: path) }))
        out.add(replacement(
                .wrongType, whole, at: tagPath, with: .number(JSONNumber(5)), expect: .typeMismatch,
                summary: "replaced the tag with a number"))

        var inner = context
        inner.genericDone = true
        if entry.isFlat {
            collect(entry.node, value, path, inner, &out)
        } else if let payload = members[union.valueKey] {
            let valuePath = path.appending(key: union.valueKey)
            out.add(make(
                    .missingRequiredKey, context, location: valuePath,
                    expected: [ExpectedIssue(path: valuePath, code: .missingKey)],
                    summary: "removed the payload \(union.valueKey)",
                    edit: { [path] in $0.removing(union.valueKey, fromObjectAt: path) }))
            inner.genericDone = false
            collect(entry.node, payload, valuePath, inner, &out)
        }
    }
}

extension SchemaNode {
    /// Whether the node is written as a JSON object, so that a wrong type is
    /// an array rather than an object.
    var isObjectLike: Bool {
        switch self {
        case .object, .union, .dictionary: true
        default: false
        }
    }
}

extension Array where Element == Mutation {
    mutating func add(_ mutation: Mutation?) {
        if let mutation { append(mutation) }
    }
}
