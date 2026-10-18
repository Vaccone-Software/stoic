public import StoicJSON

/// What a ``Schema`` is, as a value you can read.
///
/// A schema has two halves: closures that decode and encode, which can only
/// be run, and this tree, which can be walked. Everything that is not
/// decoding reads the tree: the JSON Schema exporter today; test generators,
/// a settings UI and a migration checker next. So the tree carries all the
/// facts those need (constraints, documentation, units, defaults, secrecy,
/// aliases) and nothing in it is a closure except the one that ties a
/// recursive knot.
///
/// The enum is not frozen. A reader that meets a case it does not know
/// should degrade (an exporter writes no constraints for it, a generator
/// treats it as opaque) rather than fail.
public indirect enum SchemaNode: Sendable {
    case boolean
    case integer(IntegerType, constraints: [Constraint])
    /// A `Double`.
    case number(constraints: [Constraint])
    case string(constraints: [Constraint])
    /// A string drawn from the cases of a Swift enumeration.
    case enumeration(name: String, cases: [String])
    /// An integer drawn from the cases of a Swift enumeration whose raw
    /// values are `Int`s.
    case integerEnumeration(name: String, cases: [IntegerCase])
    case array(element: SchemaNode, constraints: [Constraint])
    /// An object with arbitrary string keys and one kind of value.
    case dictionary(value: SchemaNode, constraints: [Constraint])
    /// A value that may be `nil`. `nullable` says whether JSON `null` is
    /// the spelling of `nil`; if not, `nil` is spelled by leaving the key
    /// out. See ``Schema/optional(_:nullable:)``.
    case optional(SchemaNode, nullable: Bool)
    /// Any JSON value, passed through untouched.
    case json(constraints: [Constraint])
    case object(ObjectNode)
    /// A value that is read as its base and then converted by code: a
    /// timestamp that is a string on the wire, a URL, a unit of measure.
    /// The tree records what is on the wire (the base) and how to speak of
    /// the conversion; the conversion itself is a closure, so exporters
    /// and generators treat it as opaque and rely on ``TransformNode/examples``.
    case transformed(TransformNode)
    /// A value that is one of several shapes, told apart by the value of
    /// one key: a Swift enumeration with payloads, on the wire.
    case union(UnionNode)
    /// A schema named so it can refer to itself. `resolve` produces its
    /// node on demand: calling it while the tree is being built would
    /// recurse forever, so a consumer calls it once per name and refers to
    /// the result by name after that.
    case lazy(name: String, resolve: @Sendable () -> SchemaNode)

    /// The constraints attached directly to this node.
    public var constraints: [Constraint] {
        switch self {
        case .integer(_, let constraints), .number(let constraints), .string(let constraints),
            .array(_, let constraints), .dictionary(_, let constraints), .json(let constraints):
            constraints
        case .optional(let wrapped, _): wrapped.constraints
        case .transformed(let transform): transform.base.constraints
        case .boolean, .enumeration, .integerEnumeration, .object, .union, .lazy: []
        }
    }

    /// This node with `extra` constraints appended. Used by refined types,
    /// whose constraints sit on top of their base's.
    func adding(_ extra: [Constraint]) -> SchemaNode {
        guard !extra.isEmpty else { return self }
        switch self {
        case .integer(let type, let constraints): return .integer(type, constraints: constraints + extra)
        case .number(let constraints): return .number(constraints: constraints + extra)
        case .string(let constraints): return .string(constraints: constraints + extra)
        case .array(let element, let constraints): return .array(element: element, constraints: constraints + extra)
        case .dictionary(let value, let constraints): return .dictionary(value: value, constraints: constraints + extra)
        case .json(let constraints): return .json(constraints: constraints + extra)
        case .optional(let wrapped, let nullable): return .optional(wrapped.adding(extra), nullable: nullable)
        case .transformed(var transform):
            transform.base = transform.base.adding(extra)
            return .transformed(transform)
        case .boolean, .enumeration, .integerEnumeration, .object, .union, .lazy: return self
        }
    }

    /// The kind of value this node accepts, as the phrase an issue uses:
    /// `a number`, `an array`, `one of "dark", "light"`.
    public var expectation: String {
        switch self {
        case .boolean: "a boolean"
        case .integer: "an integer"
        case .number: "a number"
        case .string: "a string"
        case .enumeration(_, let cases): "one of " + cases.map { "\"\($0)\"" }.joined(separator: ", ")
        case .array: "an array"
        case .integerEnumeration(_, let cases): "one of " + cases.map { String($0.value) }.joined(separator: ", ")
        case .dictionary, .object: "an object"
        case .transformed(let transform): transform.description
        case .union(let union): union.expectation
        case .optional(let wrapped, _): wrapped.expectation
        case .json: "any JSON value"
        case .lazy(let name, _): "a \(name)"
        }
    }
}

/// One case of an enumeration whose raw values are integers.
public struct IntegerCase: Sendable, Hashable {
    /// The Swift case's name, for documentation and UI; never on the wire.
    public var name: String
    /// The raw value, which is what the wire carries.
    public var value: Int

    public init(name: String, value: Int) {
        self.name = name
        self.value = value
    }
}

/// A conversion layered on a base schema; see ``SchemaNode/transformed(_:)``.
public struct TransformNode: Sendable {
    /// What is on the wire. Decoding reads this first, so every constraint
    /// of the base holds before the conversion runs.
    public var base: SchemaNode
    /// The Swift type the conversion produces.
    public var name: String
    /// The conversion in words, as an issue expects it: `an RFC 3339
    /// timestamp`. Exported as `x-stoic-transform`.
    public var description: String
    /// Encoded values the conversion is known to accept, for generators:
    /// a closure cannot be inspected, so the schema's author supplies the
    /// proof that some values pass. Without examples a generator can only
    /// try base values and hope.
    public var examples: [JSONValue]
    /// The JSON Schema `format` of the wire value (`date-time`, `uri`,
    /// `uuid`, `byte`), for the export and for a UI that offers a date
    /// picker rather than a text field. An annotation: a JSON Schema
    /// validator need not check it, and the one in this library does not.
    public var format: String?
    /// Further JSON Schema keywords the export writes over the base's own,
    /// such as `contentEncoding`, or a whole schema supplied for a type the
    /// library cannot look into.
    public var keywords: JSONObject
    /// Values of the base that the conversion refuses, each with the issue
    /// it raises: the invalid documents a generator cannot find on its own,
    /// because the rule they break is code.
    public var counterexamples: [Counterexample]
    /// Whether the conversion reads the digits of a number rather than a
    /// `Double`, as a decimal's does. A generator then does not offer 2^53 + 1
    /// or 1e400 as values the number refuses: whether the conversion does is
    /// for its own ``counterexamples`` to say.
    public var readsNumberDigits: Bool
    /// Whether the conversion drops the elements of an array base (or the
    /// entries of a dictionary base) that do not decode, with a warning
    /// each, instead of failing. A generator's
    /// mutation that breaks an element is then expected to cause that
    /// warning, and a JSON Schema validator, which has no such tolerance,
    /// is not asked to agree about it.
    public var dropsInvalidElements: Bool
    /// Whether the export names the conversion (`x-stoic-transform`). A
    /// Codable leaf turns any JSON value into a type and has nothing on the
    /// wire to describe, so it is exported as `{}` and nothing more.
    public var isAnnotated: Bool
    /// Whether the node changes how a valid value is read, not what it is:
    /// it converts nothing, and a generator needs no ``examples`` for it
    /// (a clamped number, a documented value). The suite does not ask such a
    /// node for examples.
    public var isTransparent = false
    /// Whether a number outside the base's inclusive range bounds is moved
    /// to the nearest bound with a warning, instead of refused (see
    /// ``Schema/clampingToRange()``). A generator's mutation past a bound is
    /// then expected to cause that warning, which a JSON Schema validator
    /// does not tolerate, so the agreement check skips it.
    public var clampsToRange = false

    /// A value the base accepts and the conversion refuses.
    public struct Counterexample: Sendable, Hashable {
        public var value: JSONValue
        /// The code of the one issue it must raise.
        public var code: IssueCode

        public init(_ value: JSONValue, code: IssueCode = .invalidValue) {
            self.value = value
            self.code = code
        }
    }

    public init(
        base: SchemaNode, name: String, description: String, examples: [JSONValue] = [], format: String? = nil,
        keywords: JSONObject = JSONObject(), counterexamples: [Counterexample] = [], readsNumberDigits: Bool = false,
        dropsInvalidElements: Bool = false, isAnnotated: Bool = true
    ) {
        self.base = base
        self.name = name
        self.description = description
        self.examples = examples
        self.format = format
        self.keywords = keywords
        self.counterexamples = counterexamples
        self.readsNumberDigits = readsNumberDigits
        self.dropsInvalidElements = dropsInvalidElements
        self.isAnnotated = isAnnotated
    }
}

/// A tagged union's shape.
public struct UnionNode: Sendable {
    /// The Swift type's name, for `title` in the export and in messages.
    public var name: String
    public var doc: String?
    /// The key whose value names the case: `type`.
    public var discriminator: String
    /// The key under which a payload that is not an object is written.
    public var valueKey: String
    public var cases: [UnionCaseNode]
    /// The name of the case a tag that names no case is read as, if the
    /// union has one (``UnknownTag``); `nil` for a closed union.
    public var unknownCase: String?

    public init(
        name: String, doc: String? = nil, discriminator: String, valueKey: String, cases: [UnionCaseNode],
        unknownCase: String? = nil
    ) {
        self.name = name
        self.doc = doc
        self.discriminator = discriminator
        self.valueKey = valueKey
        self.cases = cases
        self.unknownCase = unknownCase
    }

    /// The tags, in declaration order.
    public var tags: [String] { cases.map(\.tag) }

    var tagExpectation: String {
        "one of " + tags.map { "\"\($0)\"" }.joined(separator: ", ") + (unknownCase == nil ? "" : ", or any other string")
    }

    var expectation: String { "an object whose \"\(discriminator)\" is \(tagExpectation)" }
}

/// One alternative of a ``UnionNode``.
public struct UnionCaseNode: Sendable {
    /// The discriminator's value for this case.
    public var tag: String
    public var doc: String?
    /// The payload's schema.
    public var node: SchemaNode
    /// Whether the payload (an object) is written beside the discriminator,
    /// rather than under the union's value key.
    public var isFlat: Bool

    public init(tag: String, doc: String? = nil, node: SchemaNode, isFlat: Bool) {
        self.tag = tag
        self.doc = doc
        self.node = node
        self.isFlat = isFlat
    }
}

/// The width and signedness of an integer schema. Its natural bounds are
/// part of what the schema accepts, so the JSON Schema export states them.
public struct IntegerType: Sendable, Hashable {
    public var bitWidth: Int
    public var isSigned: Bool

    public init(bitWidth: Int, isSigned: Bool) {
        self.bitWidth = bitWidth
        self.isSigned = isSigned
    }

    public init<I: FixedWidthInteger>(_: I.Type) {
        self.init(bitWidth: I.bitWidth, isSigned: I.isSigned)
    }

    public static var int: IntegerType { IntegerType(Int.self) }
    public static var int64: IntegerType { IntegerType(Int64.self) }
    public static var uint64: IntegerType { IntegerType(UInt64.self) }

    /// The smallest value of the type.
    public var minimum: JSONNumber {
        guard isSigned else { return JSONNumber(0) }
        return bitWidth >= 64 ? JSONNumber(Int64.min) : JSONNumber(-(Int64(1) << Int64(bitWidth - 1)))
    }

    /// The largest value of the type.
    public var maximum: JSONNumber {
        if bitWidth >= 64 { return isSigned ? JSONNumber(Int64.max) : JSONNumber(UInt64.max) }
        return JSONNumber((Int64(1) << Int64(isSigned ? bitWidth - 1 : bitWidth)) - 1)
    }

    var expectation: String {
        "an integer between \(minimum.lexeme) and \(maximum.lexeme)"
    }
}

/// An object schema's shape.
public struct ObjectNode: Sendable {
    /// The Swift type's name, used for `title` in the export and in
    /// messages.
    public var name: String
    /// Documentation of the object as a whole.
    public var doc: String?
    public var fields: [FieldNode]
    public var unknownKeys: UnknownKeyPolicy
    /// The object's version and the migrations that lead to it, if it is
    /// versioned. A document's version lives in the reserved
    /// ``Versioning/key``, which is not a field.
    public var versioning: Versioning?

    public init(
        name: String, doc: String? = nil, fields: [FieldNode], unknownKeys: UnknownKeyPolicy,
        versioning: Versioning? = nil
    ) {
        self.name = name
        self.doc = doc
        self.fields = fields
        self.unknownKeys = unknownKeys
        self.versioning = versioning
    }
}

/// What an object does with a key it does not declare.
public enum UnknownKeyPolicy: Sendable, Hashable {
    /// An error, with a did-you-mean. For wire formats, where a key the
    /// receiver does not know is a message it will misread.
    case reject
    /// A warning, with a did-you-mean; the key is ignored. For
    /// configuration, where the app should start and the user should be
    /// told their `scrol_speed` did nothing.
    case warn
    /// Silence. For documents that other tools add their own keys to.
    case ignore
    /// Not an error, not even a notice: the key is kept, in a property of
    /// the Swift value that holds the keys the schema does not know, and
    /// written back unchanged. For a document that a newer release of the
    /// app, or another tool, also writes: an older release that drops
    /// what it does not understand destroys the newer one's data on its
    /// next save. A misspelt key is not noticed either, so prefer
    /// ``warn`` for a file a person edits.
    case preserve
}

/// Which spellings of a declared key an object reads.
///
/// A file a person edits is forgiven a `scroll_speed` for `scrollSpeed`; a
/// wire format is not. A reader that accepts spellings other readers do not
/// reads a document differently from them, and two readers that disagree
/// about a document are the raw material of a parser-differential attack: a
/// gateway that checks `isAdmin` while the service behind it also accepts
/// `is_admin`. So respelling is the default only where a person types the
/// document.
public enum KeySpellings: Sendable, Hashable {
    /// The key and its declared aliases, exactly as declared. Anything else
    /// is an unknown key, with the declared spelling suggested. The default
    /// for ``Schema/object(_:name:unknownKeys:spellings:doc:version:versionKey:missingVersion:migrations:declare:)``,
    /// the form for wire models.
    case exact
    /// Also any spelling that differs only in ASCII letter case or in the
    /// `_`, `-` and space between words, read with a `deprecated_key`
    /// warning naming the declared key; the same field under two spellings
    /// is `duplicate_key`. The default for
    /// ``Schema/object(_:name:default:unknownKeys:spellings:doc:version:versionKey:missingVersion:migrations:preservingUnknownKeysIn:fields:)``,
    /// the form for configuration. Only ASCII is folded: Unicode case
    /// mapping would read `\u{212A}ind` (a Kelvin sign) as `kind`.
    case forgiving
}

/// One field of an object, as the tree records it.
public struct FieldNode: Sendable {
    /// The key as written in JSON.
    public var key: String
    /// Other spellings accepted on input; each draws a `deprecated_key`
    /// warning. Never written.
    public var aliases: [String]
    public var node: SchemaNode
    /// Documentation, for the export's `description` and for UI help.
    public var doc: String?
    /// The unit of a number (`px/s`), for UI and the export's
    /// `x-stoic-unit`.
    public var unit: String?
    /// Whether the value is a secret: never echoed in an issue, never in a
    /// default of the export, left out of sparse output.
    public var isSecret: Bool
    /// Present if the field is deprecated; the message may be empty.
    public var deprecation: Deprecation?
    /// Whether the key must appear. False if the field has a default or
    /// its type is optional.
    public var isRequired: Bool
    private let defaultProvider: (@Sendable () -> JSONValue?)?

    /// The default, encoded as JSON, or `nil` if the field has none (or is
    /// secret, whose default is never exposed). Computed on demand, because
    /// encoding a default may consult a recursive schema that is still
    /// being built when the field is declared.
    public var defaultValue: JSONValue? {
        isSecret ? nil : defaultProvider?()
    }

    /// Whether a default exists, secret or not.
    public var hasDefault: Bool { defaultProvider != nil }

    init(
        key: String, aliases: [String], node: SchemaNode, doc: String?, unit: String?, isSecret: Bool,
        deprecation: Deprecation?, isRequired: Bool, defaultProvider: (@Sendable () -> JSONValue?)?
    ) {
        self.key = key
        self.aliases = aliases
        self.node = node
        self.doc = doc
        self.unit = unit
        self.isSecret = isSecret
        self.deprecation = deprecation
        self.isRequired = isRequired
        self.defaultProvider = defaultProvider
    }
}

/// Marks a field as deprecated, optionally saying what to do instead.
///
/// Written as a string literal: `Field(..., deprecated: "Use hosts.")`, or
/// `deprecated: ""` when there is nothing to add. (It is deliberately not
/// expressible by a Boolean, where `deprecated: false` would read as the
/// opposite of what it did.) A deprecated field is still read, with a
/// `deprecated_key` warning whenever a document uses it.
public struct Deprecation: Sendable, Hashable, ExpressibleByStringLiteral {
    public var message: String

    public init(_ message: String = "") {
        self.message = message
    }

    public init(stringLiteral value: String) {
        message = value
    }
}
