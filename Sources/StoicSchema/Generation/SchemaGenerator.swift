public import StoicJSON

extension Schema {
    /// Derives test inputs from the schema: valid values biased to the
    /// edges of their constraints, shrinking, and valid documents broken in
    /// one minimal way each with the expected issue recorded. See
    /// ``SchemaGenerator``.
    public var generator: SchemaGenerator<Value> {
        SchemaGenerator(self)
    }
}

/// Test inputs derived from a schema's node tree, so that a property test of
/// any schema is free and cannot drift from what the schema says.
///
/// **Valid values.** ``sample(using:)`` makes a document the schema
/// accepts, biased to where decoders fail: each bound, the values beside it,
/// zero and negative zero, empty and full collections, strings of the
/// shortest and longest lengths in whichever unit the constraint counts, with
/// astral characters, combining marks and joiner sequences, sparse documents
/// that lean on defaults and dense ones that write everything. The document
/// is decoded before it is returned, so a ``Sample`` is accepted by
/// definition; if the generator cannot make an accepted document it says why
/// instead of returning one that is not.
///
/// **Determinism.** Everything is drawn from a ``SplitMix64`` seeded by the
/// caller (or from the caller's own generator), so a failing case names a
/// seed and anyone can rebuild it.
///
/// **Shrinking.** ``shrink(_:)`` proposes simpler samples and
/// ``minimize(_:whileFailing:)`` follows them while a property keeps failing,
/// toward the minima and defaults the schema states.
///
/// **Invalid documents.** ``mutations(of:)`` lists every minimal violation a
/// valid document admits, each with the issue it must cause.
///
/// What it cannot do: a closure is opaque, so a `custom` constraint is met
/// by trying candidates and a transform is met by its declared examples (see
/// ``Schema/transform(base:decode:encode:describe:name:examples:)``).
public struct SchemaGenerator<Value: Sendable>: Sendable {
    public let schema: Schema<Value>
    public var configuration: GenerationConfiguration

    public init(_ schema: Schema<Value>, configuration: GenerationConfiguration = GenerationConfiguration()) {
        self.schema = schema
        self.configuration = configuration
    }

    // MARK: Valid values

    /// A valid sample, drawn from `generator`.
    public func sample<R: RandomNumberGenerator>(using generator: inout R) throws(GenerationFailure) -> Sample<Value> {
        var maker = ValueMaker(random: SplitMix64(seed: generator.next()), configuration: configuration)
        var lastIssues: [Issue] = []
        var lastFailure: GenerationFailure?
        for _ in 0..<20 {
            maker.resetBudget()
            do throws(GenerationFailure) {
                let document = try maker.makePresent(schema.node, depth: 0, path: .root)
                let decoded = schema.decode(document)
                if let value = decoded.value {
                    return Sample(document: document, value: value, issues: decoded.issues)
                }
                lastIssues = decoded.issues
            } catch {
                lastFailure = error
            }
        }
        if !lastIssues.isEmpty {
            throw GenerationFailure(
                "the schema refused every document the generator made; either the generator or the schema is wrong",
                issues: lastIssues)
        }
        throw lastFailure ?? GenerationFailure("no document could be made")
    }

    /// The sample for a seed. The same seed always gives the same sample.
    public func sample(seed: UInt64) throws(GenerationFailure) -> Sample<Value> {
        var random = SplitMix64(seed: seed)
        return try sample(using: &random)
    }

    public func samples(count: Int, seed: UInt64) throws(GenerationFailure) -> [Sample<Value>] {
        var random = SplitMix64(seed: seed)
        var found: [Sample<Value>] = []
        for _ in 0..<count { found.append(try sample(using: &random)) }
        return found
    }

    /// Names of the transforms in the schema that declare no examples, as
    /// paths from the root: for them the generator can only try values of the
    /// base and hope the conversion accepts them.
    public var transformsWithoutExamples: [String] {
        var found: [String] = []
        var seen: Set<String> = []
        Self.walk(schema.node, path: "$", seen: &seen) { node, path in
            if case .transformed(let transform) = node, transform.examples.isEmpty {
                found.append("\(path) (\(transform.name))")
            }
        }
        return found
    }

    /// The same, for the transforms that are a Codable leaf
    /// (``Schema/codable(_:examples:decoding:encoding:)``): a typed value
    /// refuses almost any JSON a generator draws, so for them examples are
    /// not an improvement but the only way to generate anything.
    var codableLeavesWithoutExamples: [String] {
        var found: [String] = []
        var seen: Set<String> = []
        Self.walk(schema.node, path: "$", seen: &seen) { node, path in
            if case .transformed(let transform) = node, transform.examples.isEmpty, !transform.isAnnotated {
                found.append("\(path) (\(transform.name))")
            }
        }
        return found
    }

    static func walk(_ node: SchemaNode, path: String, seen: inout Set<String>, visit: (SchemaNode, String) -> Void) {
        visit(node, path)
        switch node {
        case .array(let element, _): walk(element, path: path + "[]", seen: &seen, visit: visit)
        case .dictionary(let element, _): walk(element, path: path + ".*", seen: &seen, visit: visit)
        case .optional(let wrapped, _): walk(wrapped, path: path, seen: &seen, visit: visit)
        case .transformed(let transform): walk(transform.base, path: path, seen: &seen, visit: visit)
        case .object(let object):
            for field in object.fields { walk(field.node, path: path + "." + field.key, seen: &seen, visit: visit) }
        case .union(let union):
            for entry in union.cases { walk(entry.node, path: path + "<" + entry.tag + ">", seen: &seen, visit: visit) }
        case .lazy(let name, let resolve):
            if seen.insert(name).inserted { walk(resolve(), path: path, seen: &seen, visit: visit) }
        case .boolean, .integer, .number, .string, .enumeration, .integerEnumeration, .json:
            break
        }
    }

    // MARK: Shrinking

    /// Simpler versions of `sample` that the schema accepts, simplest first.
    public func shrink(_ sample: Sample<Value>) -> [Sample<Value>] {
        var found: [Sample<Value>] = []
        for candidate in Shrinker.candidates(schema.node, sample.document) {
            let decoded = schema.decode(candidate)
            if let value = decoded.value {
                found.append(Sample(document: candidate, value: value, issues: decoded.issues))
            }
        }
        return found
    }

    /// The simplest sample reachable from `sample` by shrinking, one that
    /// still makes `property` fail (return `true`).
    ///
    /// Greedy: it takes the first simpler sample that still fails and starts
    /// again from it, so the result is a local minimum, which is what a
    /// person wants to read in a failure report.
    public func minimize(_ sample: Sample<Value>, whileFailing fails: (Value) -> Bool) -> Sample<Value> {
        var current = sample
        for _ in 0..<500 {
            guard let next = shrink(current).first(where: { fails($0.value) }) else { break }
            current = next
        }
        return current
    }

    // MARK: Invalid documents

    /// Every minimal violation `document` admits, in a stable order.
    ///
    /// Each mutation breaks exactly one rule (below a bound, above one, the
    /// wrong kind of value, `null`, a missing required key, an unknown key, a
    /// misspelt key, a string too long or too short, a collection too big or
    /// too small, a repeated element, a value that is not a multiple, a
    /// pattern mismatch, a bad enumeration case, a bad union tag, a missing
    /// discriminator, a number that loses precision, a version from the
    /// future) and records the issue it must cause. Which are offered depends
    /// on the schema and the document: a schema with no upper bound has no
    /// "above" mutation.
    ///
    /// - Parameter seed: Chooses the fresh elements a collection grows by.
    public func mutations(of document: JSONValue, seed: UInt64 = 0) -> [Mutation] {
        var mutator = Mutator(maker: ValueMaker(random: SplitMix64(seed: seed), configuration: configuration))
        return mutator.mutations(of: document, node: schema.node)
    }

    /// One randomly chosen mutation of `document`, or `nil` if it admits none.
    public func mutation<R: RandomNumberGenerator>(of document: JSONValue, using generator: inout R) -> Mutation? {
        let all = mutations(of: document, seed: generator.next())
        guard !all.isEmpty else { return nil }
        return all[Int.random(in: 0..<all.count, using: &generator)]
    }

    /// `count` mutations that do not touch one another's parts of the
    /// document, applied together; its expected issues are all of theirs.
    /// A decoder that accumulates reports exactly that many. Fewer than
    /// `count` are combined if the document does not admit that many
    /// independent ones.
    public func mutation<R: RandomNumberGenerator>(
        of document: JSONValue,
        combining count: Int,
        using generator: inout R
    ) -> Mutation? {
        var all = mutations(of: document, seed: generator.next())
        all.shuffle(using: &generator)
        var chosen: [Mutation] = []
        for candidate in all where chosen.count < count {
            if chosen.allSatisfy({ !$0.location.overlaps(candidate.location) }) { chosen.append(candidate) }
        }
        guard var combined = chosen.first else { return nil }
        var edited = document
        for part in chosen {
            guard let next = part.edit(edited) else { return nil }
            edited = next
        }
        combined.document = edited
        combined.expected = chosen.flatMap(\.expected)
        combined.summary = chosen.map(\.summary).joined(separator: "; ")
        combined.location = .root
        return combined
    }

    /// A valid sample broken in one minimal way.
    public func invalidDocument<R: RandomNumberGenerator>(using generator: inout R) throws(GenerationFailure) -> Mutation {
        for _ in 0..<10 {
            let valid = try sample(using: &generator)
            if let broken = mutation(of: valid.document, using: &generator) { return broken }
        }
        throw GenerationFailure("the schema admits no violation of its constraints")
    }
}
