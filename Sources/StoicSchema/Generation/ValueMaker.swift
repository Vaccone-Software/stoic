internal import StoicJSON

/// Derives valid JSON from a schema's node tree, biased toward the edges.
///
/// Every decision is the node's: a range yields its bounds, the values next
/// to them and a point between; a length yields the shortest, the longest and
/// the lengths beside them; a collection yields empty, full and in between;
/// a string draws from ASCII, accented letters, CJK, astral emoji, combining
/// marks and ZWJ sequences, measured in whichever unit the length constraint
/// counts. Constraints it cannot satisfy by construction (`custom`, an
/// unsupported pattern) are met by drawing candidates and keeping those the
/// real checker accepts, so the checker is the judge and the generator only
/// proposes.
struct ValueMaker {
    var random: SplitMix64
    let configuration: GenerationConfiguration
    private var checker = ConstraintChecker()
    /// Set when a value was made for a transform that declares no examples.
    private(set) var usedUnexemplifiedTransform = false
    /// How many more nodes this document may have before everything optional
    /// is left out and every collection is as small as it may be. A
    /// recursive schema with a branching factor of eight would otherwise
    /// make a document with millions of nodes.
    private var budget = 400

    init(random: SplitMix64, configuration: GenerationConfiguration) {
        self.random = random
        self.configuration = configuration
    }

    mutating func resetBudget() { budget = 400 }

    /// Whether the document should stop growing here.
    private func isDeep(_ depth: Int) -> Bool {
        depth >= configuration.maxDepth || budget <= 0
    }

    // MARK: Randomness

    mutating func chance(_ percent: Int) -> Bool {
        Int.random(in: 0..<100, using: &random) < percent
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        return Int.random(in: range, using: &random)
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[Int.random(in: 0..<items.count, using: &random)]
    }

    // MARK: Entry

    /// A value for `node`; `nil` only for an optional that was left out.
    mutating func make(_ node: SchemaNode, depth: Int = 0, path: JSONPath = .root) throws(GenerationFailure) -> JSONValue? {
        budget -= 1
        switch node {
        case .boolean:
            return .bool(chance(50))

        case .integer(let type, let constraints):
            return try makeInteger(type, constraints, path: path)

        case .number(let constraints):
            return try makeNumber(constraints, path: path)

        case .string(let constraints):
            return try makeString(constraints, path: path)

        case .enumeration(_, let cases):
            guard !cases.isEmpty else { throw GenerationFailure("an enumeration with no cases", path: path) }
            return .string(pickBiased(cases))

        case .integerEnumeration(_, let cases):
            guard !cases.isEmpty else { throw GenerationFailure("an enumeration with no cases", path: path) }
            return .number(JSONNumber(pickBiased(cases).value))

        case .array(let element, let constraints):
            return try makeArray(element, constraints, depth: depth, path: path)

        case .dictionary(let value, let constraints):
            return try makeDictionary(value, constraints, depth: depth, path: path)

        case .optional(let wrapped, let nullable):
            let absence = isDeep(depth) ? 90 : 35
            if chance(absence) { return nil }
            if nullable && chance(15) { return .null }
            return try make(wrapped, depth: depth, path: path)

        case .json(let constraints):
            return try makeJSON(constraints, path: path)

        case .object(let object):
            return try makeObject(object, depth: depth, path: path)

        case .transformed(let transform):
            if !transform.examples.isEmpty {
                return pick(transform.examples)
            }
            usedUnexemplifiedTransform = true
            return try make(transform.base, depth: depth, path: path)

        case .union(let union):
            return try makeUnion(union, depth: depth, path: path)

        case .lazy(_, let resolve):
            guard depth < configuration.maxDepth + 4 else {
                throw GenerationFailure("recursion did not end", path: path)
            }
            return try make(resolve(), depth: depth + 1, path: path)
        }
    }

    /// Like ``make(_:depth:path:)`` for a place that cannot be left empty:
    /// an array element, a union payload.
    mutating func makePresent(_ node: SchemaNode, depth: Int, path: JSONPath) throws(GenerationFailure) -> JSONValue {
        if case .optional(let wrapped, let nullable) = node {
            if nullable && chance(15) { return .null }
            return try makePresent(wrapped, depth: depth, path: path)
        }
        guard let value = try make(node, depth: depth, path: path) else {
            throw GenerationFailure("a value was needed here", path: path)
        }
        return value
    }

    private mutating func pickBiased<T>(_ items: [T]) -> T {
        // The first and last case are where enumerations go wrong.
        switch Int.random(in: 0..<5, using: &random) {
        case 0: return items[0]
        case 1: return items[items.count - 1]
        default: return pick(items)
        }
    }

    /// The first of `candidates` that satisfies `constraints`, chosen at random
    /// among those that do.
    private mutating func satisfying(_ candidates: [JSONValue], _ constraints: [Constraint]) -> [JSONValue] {
        candidates.filter { checker.violations(of: constraints, in: $0).isEmpty }
    }

    // MARK: Integers

    private static func ceiling(_ number: JSONNumber, exclusive: Bool) -> Int128? {
        let whole: Int128
        if let value = number.integralInt64 {
            whole = Int128(value)
        } else if let value = number.integralUInt64 {
            whole = Int128(value)
        } else if let double = Double(number.lexeme), double.isFinite, let value = Int128(exactly: double.rounded(.up)) {
            return value
        } else {
            return nil
        }
        return exclusive ? whole + 1 : whole
    }

    private static func floor(_ number: JSONNumber, exclusive: Bool) -> Int128? {
        let whole: Int128
        if let value = number.integralInt64 {
            whole = Int128(value)
        } else if let value = number.integralUInt64 {
            whole = Int128(value)
        } else if let double = Double(number.lexeme), double.isFinite, let value = Int128(exactly: double.rounded(.down)) {
            return value
        } else {
            return nil
        }
        return exclusive ? whole - 1 : whole
    }

    /// The integers the type and the range constraints allow together.
    static func integerBounds(_ type: IntegerType, _ constraints: [Constraint]) -> (low: Int128, high: Int128) {
        var low = Int128(type.minimum.lexeme) ?? Int128(Int64.min)
        var high = Int128(type.maximum.lexeme) ?? Int128(Int64.max)
        for constraint in constraints {
            guard case .range(let range) = constraint.kind else { continue }
            if let bound = range.lower, let value = ceiling(bound.value, exclusive: !bound.isInclusive) {
                low = max(low, value)
            }
            if let bound = range.upper, let value = floor(bound.value, exclusive: !bound.isInclusive) {
                high = min(high, value)
            }
        }
        return (low, high)
    }

    private mutating func makeInteger(
        _ type: IntegerType,
        _ constraints: [Constraint],
        path: JSONPath
    ) throws(GenerationFailure) -> JSONValue {
        let (low, high) = Self.integerBounds(type, constraints)
        guard low <= high else { throw GenerationFailure("no integer satisfies the range", path: path) }
        var edge: [Int128] = [low, low + 1, high - 1, high, 0, 1, -1, 2, 7, 10, 100, 255, 256, 1000, 4096, 65_535, 65_536]
        edge.append(low + (high - low) / 2)
        edge.append(Int128(1) << 53 > high ? high : Int128(1) << 53)
        edge.append(Int128(1) << 31)
        for constraint in constraints {
            if case .multipleOf(let step) = constraint.kind, let whole = Self.ceiling(step, exclusive: false), whole > 0 {
                let first = (low + whole - 1) / whole * whole  // low >= 0 case; negative handled by the filter
                edge.append(contentsOf: [first, first + whole, high / whole * whole, 0])
                if low < 0 { edge.append(-((-low) / whole) * whole) }
            }
            if case .oneOf(let values) = constraint.kind {
                edge.append(contentsOf: values.compactMap { $0.number?.integralInt64.map { Int128($0) } })
            }
        }
        let boundary = satisfying(
            edge.filter { $0 >= low && $0 <= high }.map { JSONValue.number(JSONNumber($0)) }, constraints)
        if !boundary.isEmpty, chance(55) { return pick(boundary) }
        for _ in 0..<20 {
            let candidate = JSONValue.number(JSONNumber(Int128.random(in: low...high, using: &random)))
            if checker.violations(of: constraints, in: candidate).isEmpty { return candidate }
        }
        if !boundary.isEmpty { return pick(boundary) }
        throw GenerationFailure("no integer found that satisfies \(constraints.map(\.description))", path: path)
    }

    // MARK: Doubles

    private mutating func makeNumber(_ constraints: [Constraint], path: JSONPath) throws(GenerationFailure) -> JSONValue {
        var low: Double?
        var high: Double?
        var steps: [Double] = []
        for constraint in constraints {
            switch constraint.kind {
            case .range(let range):
                if let bound = range.lower, let value = bound.value.double {
                    let adjusted = bound.isInclusive ? value : value.nextUp
                    low = max(low ?? -.infinity, adjusted)
                }
                if let bound = range.upper, let value = bound.value.double {
                    let adjusted = bound.isInclusive ? value : value.nextDown
                    high = min(high ?? .infinity, adjusted)
                }
            case .multipleOf(let step):
                if let value = step.double, value > 0 { steps.append(value) }
            default:
                break
            }
        }
        if let low, let high, low > high { throw GenerationFailure("no number satisfies the range", path: path) }
        var edge: [Double] = [0, -0.0, 1, -1, 0.5, 2, 10, 100, 1000]
        if let low {
            edge.append(contentsOf: [low, low.nextUp])
        } else {
            edge.append(contentsOf: [-1e6, -9_007_199_254_740_992, -Double.greatestFiniteMagnitude])
        }
        if let high {
            edge.append(contentsOf: [high, high.nextDown])
        } else {
            edge.append(contentsOf: [1e6, 9_007_199_254_740_992, Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude])
        }
        if let low, let high {
            edge.append(contentsOf: [low + 1, high - 1])
            edge.append(low + (high - low) / 2)
            edge.append(low + (high - low) / 4)
            edge.append(low + (high - low) * 3 / 4)
        }
        for step in steps {
            let from = low ?? -1000
            let to = high ?? 1000
            edge.append(contentsOf: [(from / step).rounded(.up) * step, (to / step).rounded(.down) * step, step, 0])
        }
        let boundary = satisfying(
            edge.compactMap { JSONNumber($0).map { JSONValue.number($0) } }, constraints)
        if !boundary.isEmpty, chance(55) { return pick(boundary) }
        let lowest = max(low ?? ((high ?? 0) - 1e6), -1e300)
        let highest = min(high ?? ((low ?? 0) + 1e6), 1e300)
        for _ in 0..<30 {
            var value = lowest <= highest ? Double.random(in: lowest...highest, using: &random) : lowest
            if chance(50) {
                // Numbers people write have few digits.
                let rounded = (value * 100).rounded() / 100
                if rounded >= lowest, rounded <= highest { value = rounded }
            }
            for step in steps { value = (value / step).rounded() * step }
            if let number = JSONNumber(value), checker.violations(of: constraints, in: .number(number)).isEmpty {
                return .number(number)
            }
        }
        if !boundary.isEmpty { return pick(boundary) }
        throw GenerationFailure("no number found that satisfies \(constraints.map(\.description))", path: path)
    }

    // MARK: Strings

    private struct Piece {
        var text: String
        var scalars: Int
        var graphemes: Int
        var bytes: Int

        func cost(_ unit: LengthUnit) -> Int {
            switch unit {
            case .characters: scalars
            case .graphemes: graphemes
            case .utf8Bytes: bytes
            }
        }
    }

    private static let plainLetters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// Pieces that are not ASCII letters. Each is one grapheme except where
    /// noted, and none starts with a combining mark or ends with a joiner, so
    /// pieces placed side by side stay separate graphemes.
    private static let unusual: [Piece] = [
        Piece(text: "\u{E9}", scalars: 1, graphemes: 1, bytes: 2),  // é
        Piece(text: "\u{DF}", scalars: 1, graphemes: 1, bytes: 2),  // ß
        Piece(text: "\u{4E2D}", scalars: 1, graphemes: 1, bytes: 3),  // 中
        Piece(text: "\u{1F600}", scalars: 1, graphemes: 1, bytes: 4),  // 😀
        Piece(text: "\u{1D11E}", scalars: 1, graphemes: 1, bytes: 4),  // 𝄞, astral, not an emoji
        Piece(text: "e\u{301}", scalars: 2, graphemes: 1, bytes: 3),  // e + combining acute
        Piece(text: "a\u{300}\u{323}", scalars: 3, graphemes: 1, bytes: 5),  // two combining marks
        Piece(text: "\u{1F44D}\u{1F3FD}", scalars: 2, graphemes: 1, bytes: 8),  // thumbs up, skin tone
        Piece(text: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", scalars: 5, graphemes: 1, bytes: 18),  // ZWJ family
        Piece(text: "\u{1F1EF}\u{1F1F5}", scalars: 2, graphemes: 1, bytes: 8),  // flag: one grapheme, two scalars
        Piece(text: "\u{AC00}", scalars: 1, graphemes: 1, bytes: 3),  // Hangul syllable
        Piece(text: "\u{FF21}", scalars: 1, graphemes: 1, bytes: 3),  // fullwidth A
    ]

    /// ASCII that a JSON writer must escape or a careless one forgets to.
    private static let awkward: [Piece] = [
        Piece(text: "\"", scalars: 1, graphemes: 1, bytes: 1),
        Piece(text: "\\", scalars: 1, graphemes: 1, bytes: 1),
        Piece(text: "/", scalars: 1, graphemes: 1, bytes: 1),
        Piece(text: " ", scalars: 1, graphemes: 1, bytes: 1),
        Piece(text: "\t", scalars: 1, graphemes: 1, bytes: 1),
        Piece(text: "\u{1}", scalars: 1, graphemes: 1, bytes: 1),
        Piece(text: "\u{7F}", scalars: 1, graphemes: 1, bytes: 1),
    ]

    /// A string whose length in `unit` is exactly `length`.
    mutating func string(length: Int, unit: LengthUnit, unicode: Bool) -> String {
        var out = ""
        var remaining = length
        while remaining > 0 {
            if unicode && chance(35) {
                let fitting = Self.unusual.filter { $0.cost(unit) <= remaining }
                if !fitting.isEmpty {
                    let piece = pick(fitting)
                    out += piece.text
                    remaining -= piece.cost(unit)
                    continue
                }
            }
            if chance(unicode ? 6 : 3) {
                out += pick(Self.awkward).text
            } else {
                out.append(pick(Self.plainLetters))
            }
            remaining -= 1
        }
        return out
    }

    private mutating func makeString(_ constraints: [Constraint], path: JSONPath) throws(GenerationFailure) -> JSONValue {
        var oneOf: [JSONValue]?
        var patterns: [String] = []
        var lengths: [(CountRange, LengthUnit)] = []
        for constraint in constraints {
            switch constraint.kind {
            case .oneOf(let values): oneOf = values
            case .pattern(let source): patterns.append(source)
            case .length(let range, let unit): lengths.append((range, unit))
            default: break
            }
        }
        if let oneOf {
            let valid = satisfying(oneOf.filter { $0.string != nil }, constraints)
            guard !valid.isEmpty else { throw GenerationFailure("no allowed string satisfies the constraints", path: path) }
            return pick(valid)
        }
        if let source = patterns.first {
            return try makeMatching(source, constraints, path: path)
        }

        var low = 0
        var high = Int.max
        var unit = LengthUnit.characters
        let units = Set(lengths.map(\.1))
        for (range, _) in lengths {
            low = max(low, range.lower ?? 0)
            high = min(high, range.upper ?? Int.max)
        }
        if units.count == 1, let only = units.first { unit = only }
        guard low <= high else { throw GenerationFailure("no string satisfies the lengths", path: path) }
        high = min(high, max(low, configuration.maxStringLength))
        let target = pickLength(low: low, high: high)
        // With one unit anything goes; with several only ASCII counts the same
        // in all of them.
        let unicode = units.count <= 1 && chance(55)
        let candidate = JSONValue.string(string(length: target, unit: unit, unicode: unicode))
        if checker.violations(of: constraints, in: candidate).isEmpty { return candidate }
        let plain = JSONValue.string(string(length: target, unit: unit, unicode: false))
        if checker.violations(of: constraints, in: plain).isEmpty { return plain }
        throw GenerationFailure("could not make a string of length \(target) that satisfies the constraints", path: path)
    }

    /// A length in `low...high`, often an end or next to one.
    mutating func pickLength(low: Int, high: Int) -> Int {
        var pool = [low, low + 1, high - 1, high, 0, 1, 2]
        pool = pool.filter { $0 >= low && $0 <= high }
        if chance(60), !pool.isEmpty { return pick(pool) }
        return int(low...high)
    }

    private mutating func makeMatching(
        _ source: String,
        _ constraints: [Constraint],
        path: JSONPath
    ) throws(GenerationFailure) -> JSONValue {
        var valid: [JSONValue] = []
        if let sampler = RegexSampler(pattern: source) {
            for attempt in 0..<40 {
                let candidate = JSONValue.string(sampler.sample(using: &random, short: attempt % 3 == 0))
                if checker.violations(of: constraints, in: candidate).isEmpty { valid.append(candidate) }
                if valid.count >= 4 { break }
            }
        }
        if valid.isEmpty {
            // A pattern the sampler does not understand: try what usually matches.
            valid = satisfying(["", "a", "abc", "0", "1", "example", "a-b", "A1", "x.y"].map { JSONValue.string($0) }, constraints)
        }
        guard !valid.isEmpty else {
            throw GenerationFailure("could not make a string that matches /\(source)/ and the other constraints", path: path)
        }
        return pick(valid)
    }

    // MARK: Collections

    private func countBounds(_ constraints: [Constraint], minimumAllowed: Int = 0) -> (low: Int, high: Int) {
        var low = 0
        var high = Int.max
        for constraint in constraints {
            guard case .count(let range) = constraint.kind else { continue }
            low = max(low, range.lower ?? 0)
            high = min(high, range.upper ?? Int.max)
        }
        return (low, min(high, max(low, configuration.maxCollectionSize)))
    }

    private mutating func makeArray(
        _ element: SchemaNode,
        _ constraints: [Constraint],
        depth: Int,
        path: JSONPath
    ) throws(GenerationFailure) -> JSONValue {
        let (low, high) = countBounds(constraints)
        guard low <= high else { throw GenerationFailure("no count satisfies the constraints", path: path) }
        let unique = constraints.contains { $0.kind == .unique }
        let target = isDeep(depth) ? low : pickLength(low: low, high: high)
        var items: [JSONValue] = []
        var attempts = 0
        while items.count < target && attempts < target * 20 + 20 {
            attempts += 1
            let item = try makePresent(element, depth: depth, path: path.appending(index: items.count))
            if unique && items.contains(item) { continue }
            items.append(item)
        }
        guard items.count >= low else {
            throw GenerationFailure("could not make \(low) distinct elements", path: path)
        }
        return .array(items)
    }

    private mutating func makeDictionary(
        _ value: SchemaNode,
        _ constraints: [Constraint],
        depth: Int,
        path: JSONPath
    ) throws(GenerationFailure) -> JSONValue {
        let (low, high) = countBounds(constraints)
        guard low <= high else { throw GenerationFailure("no count satisfies the constraints", path: path) }
        let target = isDeep(depth) ? low : pickLength(low: low, high: high)
        var entries = JSONObject()
        var seen: Set<String> = []
        var attempts = 0
        while entries.count < target && attempts < target * 20 + 20 {
            attempts += 1
            let key = string(length: int(1...10), unit: .characters, unicode: chance(40))
            // Swift's String treats canonically equivalent keys as one; the
            // dictionary schema refuses such pairs, so never make them.
            guard seen.insert(key).inserted else { continue }
            entries[key] = try makePresent(value, depth: depth, path: path.appending(key: key))
        }
        guard entries.count >= low else { throw GenerationFailure("could not make \(low) keys", path: path) }
        return .object(entries)
    }

    // MARK: Any JSON

    private mutating func makeJSON(_ constraints: [Constraint], path: JSONPath) throws(GenerationFailure) -> JSONValue {
        for constraint in constraints {
            if case .oneOf(let values) = constraint.kind {
                let valid = satisfying(values, constraints)
                guard !valid.isEmpty else { throw GenerationFailure("no allowed value satisfies the constraints", path: path) }
                return pick(valid)
            }
        }
        for _ in 0..<20 {
            let candidate = anyJSON(depth: 0)
            if checker.violations(of: constraints, in: candidate).isEmpty { return candidate }
        }
        throw GenerationFailure("could not make a JSON value that satisfies \(constraints.map(\.description))", path: path)
    }

    private mutating func anyJSON(depth: Int) -> JSONValue {
        switch Int.random(in: 0..<(depth >= 2 ? 5 : 7), using: &random) {
        case 0: return .null
        case 1: return .bool(chance(50))
        case 2: return .number(JSONNumber(int(-1000...1000)))
        case 3: return .string(string(length: int(0...8), unit: .characters, unicode: chance(40)))
        case 4: return .number(JSONNumber(Double(int(-100...100)) / 4) ?? JSONNumber(0))
        case 5:
            return .array((0..<int(0...3)).map { _ in anyJSON(depth: depth + 1) })
        default:
            var object = JSONObject()
            for _ in 0..<int(0...3) {
                object[string(length: int(1...6), unit: .characters, unicode: false)] = anyJSON(depth: depth + 1)
            }
            return .object(object)
        }
    }

    // MARK: Objects

    private mutating func makeObject(_ object: ObjectNode, depth: Int, path: JSONPath) throws(GenerationFailure) -> JSONValue {
        // Documents come in three styles: everything written out, nothing but
        // what is required (the sparse file), and a mixture.
        enum Style { case dense, sparse, mixed }
        let style: Style
        switch Int.random(in: 0..<10, using: &random) {
        case 0..<4: style = .dense
        case 4..<6: style = .sparse
        default: style = .mixed
        }
        var result = JSONObject()
        if let versioning = object.versioning {
            result[versioning.key] = .number(JSONNumber(versioning.current))
        }
        for field in object.fields {
            let fieldPath = path.appending(key: field.key)
            if field.isRequired {
                result[field.key] = try makePresent(field.node, depth: depth, path: fieldPath)
                continue
            }
            if field.deprecation != nil, chance(80) { continue }
            let omission: Int
            switch style {
            case .dense: omission = 4
            case .sparse: omission = 85
            case .mixed: omission = 35
            }
            if isDeep(depth) || chance(omission) { continue }
            if case .optional(let inner, let nullable) = field.node {
                if nullable && chance(15) {
                    result[field.key] = .null
                } else {
                    result[field.key] = try makePresent(inner, depth: depth, path: fieldPath)
                }
                continue
            }
            if let explicit = field.defaultValue, chance(15) {
                result[field.key] = explicit
                continue
            }
            result[field.key] = try makePresent(field.node, depth: depth, path: fieldPath)
        }
        return .object(result)
    }

    // MARK: Unions

    private mutating func makeUnion(_ union: UnionNode, depth: Int, path: JSONPath) throws(GenerationFailure) -> JSONValue {
        var order = Array(union.cases.indices)
        order.shuffle(using: &random)
        if isDeep(depth) {
            // Deep in a recursion, cases that recurse go last.
            order.sort { Self.recurses(union.cases[$0].node) ? false : Self.recurses(union.cases[$1].node) }
        }
        var lastFailure: GenerationFailure?
        for index in order {
            let entry = union.cases[index]
            do throws(GenerationFailure) {
                let payload = try makePresent(entry.node, depth: depth, path: path)
                var result = JSONObject()
                result[union.discriminator] = .string(entry.tag)
                if entry.isFlat, case .object(let members) = payload {
                    for member in members { result[member.key] = member.value }
                } else {
                    result[union.valueKey] = payload
                }
                return .object(result)
            } catch {
                lastFailure = error
            }
        }
        throw lastFailure ?? GenerationFailure("a union with no cases", path: path)
    }

    /// Whether a node refers back to something (a `lazy` below it).
    static func recurses(_ node: SchemaNode) -> Bool {
        switch node {
        case .lazy: true
        case .array(let element, _): recurses(element)
        case .dictionary(let value, _): recurses(value)
        case .optional(let wrapped, _): recurses(wrapped)
        case .transformed(let transform): recurses(transform.base)
        case .object(let object): object.fields.contains { recurses($0.node) }
        case .union(let union): union.cases.contains { recurses($0.node) }
        case .boolean, .integer, .number, .string, .enumeration, .integerEnumeration, .json: false
        }
    }
}
