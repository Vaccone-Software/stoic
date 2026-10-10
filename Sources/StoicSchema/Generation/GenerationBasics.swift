public import StoicJSON

/// A small, fast, seedable random number generator (SplitMix64).
///
/// Generators and the suite are deterministic: the same seed gives the same
/// values on every machine and every run, so a failure that names its seed
/// can be reproduced by anyone. The standard library's system generator is
/// not seedable, and `RandomNumberGenerator` has no seeded implementation
/// of its own.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// How large the generated values may grow.
///
/// A schema may allow ten thousand elements or a million-character string;
/// a generator that always produced the full amount would make every test
/// slow. Bounds above these limits are still exercised (the largest value
/// below the limit is generated, and violations of the bound are built by
/// the mutation generator when they are within reach), but a "full"
/// collection means the limit, not the bound.
public struct GenerationConfiguration: Sendable, Hashable {
    /// The most elements of an array or entries of a dictionary.
    public var maxCollectionSize: Int
    /// The most Unicode scalars of a string with no tighter upper bound,
    /// and the cap on a string that has one.
    public var maxStringLength: Int
    /// How deeply a recursive schema may nest before generation ends the
    /// recursion at the smallest value it can.
    public var maxDepth: Int

    public init(maxCollectionSize: Int = 16, maxStringLength: Int = 512, maxDepth: Int = 5) {
        self.maxCollectionSize = maxCollectionSize
        self.maxStringLength = maxStringLength
        self.maxDepth = maxDepth
    }
}

/// Why a generator could not make a value.
public struct GenerationFailure: Error, Sendable, CustomStringConvertible {
    public var message: String
    /// Where in the schema the generator gave up.
    public var path: JSONPath
    /// The issues the schema reported when a value the generator made was
    /// not accepted, if that is what happened.
    public var issues: [Issue]

    public init(_ message: String, path: JSONPath = .root, issues: [Issue] = []) {
        self.message = message
        self.path = path
        self.issues = issues
    }

    public var description: String {
        var text = "cannot generate a value at \(path): \(message)"
        if !issues.isEmpty { text += "\n" + issues.map(\.description).joined(separator: "\n") }
        return text
    }
}

/// A generated valid value together with the document it came from.
public struct Sample<Value: Sendable>: Sendable {
    /// The JSON the schema accepted.
    public var document: JSONValue
    /// What the schema made of it.
    public var value: Value
    /// The warnings and notices the schema raised for the document (a
    /// deprecated field that was generated, say).
    public var issues: [Issue]
}
