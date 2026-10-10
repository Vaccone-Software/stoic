public import StoicJSON

/// One step in the history of a document's format: the changes that turn a
/// document of version `from` into one of version `to`.
///
///     .from(1, to: 2,
///           .rename("scroll_speed", to: "scrollSpeed"),
///           .pinDefault("zoom", 1.0))
///     .from(2, to: 3,
///           .move("hosts", to: "network.hosts"),
///           .mapEnum("mode", ["fast": "turbo"]))
///
/// A migration works on the JSON, never on a Swift value, so the types of
/// old releases need not be kept alive to read their files. Its operations
/// are a closed set of declarative edits (and one labelled escape hatch,
/// ``Operation/custom(id:description:apply:inverse:)``), which is what lets
/// a checker reason about them: the export lists them, and
/// ``Schema/migrationChainCheck()`` runs them backwards to build old
/// documents and forwards to prove they arrive.
///
/// Steps are applied one at a time, in order, until the document reaches
/// the schema's version, and each applied step is reported as a `migrated`
/// warning, so a person who edits a file by hand learns that the app
/// rewrote their old spelling.
public struct Migration: Sendable, Hashable {
    /// The version this step reads.
    public var from: Int
    /// The version this step produces.
    public var to: Int
    public var operations: [Operation]

    public init(from: Int, to: Int, operations: [Operation]) {
        self.from = from
        self.to = to
        self.operations = operations
    }

    /// A step from one version to a later one.
    public static func from(_ from: Int, to: Int, _ operations: Operation...) -> Migration {
        Migration(from: from, to: to, operations: operations)
    }

    /// One edit of the document. Paths are keys separated by dots
    /// (`network.hosts`); a key that contains a dot cannot be addressed,
    /// and needs a ``custom(id:description:apply:inverse:)`` operation. A
    /// path that does not exist in the document is skipped, never an error:
    /// an old file need not have had every field.
    public struct Operation: Sendable, Hashable, CustomStringConvertible {
        /// What the operation does, as data.
        public enum Kind: Sendable, Hashable {
            /// Gives the value at `path` a new last key `name`, keeping its
            /// place in the same object. An error if `name` is taken.
            case rename(path: String, name: String)
            /// Takes the value at `from` to `to`, creating the objects on
            /// the way. An error if `to` is taken.
            case move(from: String, to: String)
            /// Removes the value at `path`. `example` is what such a value
            /// could have been, used only to build old documents in a chain
            /// check; without it the check builds documents that lack the
            /// field.
            case delete(path: String, example: JSONValue?)
            /// Sets `path` to `value` unless it is present.
            case setIfAbsent(path: String, value: JSONValue)
            /// Replaces the string at `path` by its image under `mapping`;
            /// strings the mapping does not mention are left alone.
            case mapEnum(path: String, mapping: [String: String])
            /// Writes the value that was the default of an earlier version
            /// into a document that left the field out. See
            /// ``Operation/pinDefault(_:_:)``.
            case pinDefault(path: String, value: JSONValue)
            /// An edit only code can state.
            case custom(Custom)
        }

        public var kind: Kind

        public init(_ kind: Kind) {
            self.kind = kind
        }

        /// Renames the value at `path` to `name`: `.rename("scroll_speed", to: "scrollSpeed")`,
        /// or `.rename("network.hosts", to: "servers")` for a nested key.
        public static func rename(_ path: String, to name: String) -> Operation {
            Operation(.rename(path: path, name: name))
        }

        /// Moves the value at `from` to `to`: `.move("hosts", to: "network.hosts")`.
        public static func move(_ from: String, to: String) -> Operation {
            Operation(.move(from: from, to: to))
        }

        /// Removes a field the new version no longer has.
        ///
        /// - Parameter example: A value the removed field could hold, so
        ///   that ``Schema/migrationChainCheck()`` can build an old document
        ///   that has it and prove the operation removes it.
        public static func delete(_ path: String, example: JSONValue? = nil) -> Operation {
            Operation(.delete(path: path, example: example))
        }

        /// Sets a field the new version requires, if the old document lacks it.
        public static func setIfAbsent(_ path: String, _ value: JSONValue) -> Operation {
            Operation(.setIfAbsent(path: path, value: value))
        }

        /// Renames the values of an enumeration: `.mapEnum("mode", ["fast": "turbo"])`.
        public static func mapEnum(_ path: String, _ mapping: [String: String]) -> Operation {
            Operation(.mapEnum(path: path, mapping: mapping))
        }

        /// Writes an old default explicitly, so that changing a default
        /// never changes what a document means.
        ///
        /// A sparse document leaves out every field that equals its default.
        /// If release 2 changes `scrollSpeed`'s default from 600 to 1200, a
        /// release 1 file that omits it meant 600, and without this
        /// operation it would be read as 1200: the user's value flips and
        /// nothing says so. `.pinDefault("scrollSpeed", 600)` in the 1→2
        /// step writes 600 into any file that left it out. Files that
        /// already say something are untouched.
        ///
        /// It does what ``setIfAbsent(_:_:)`` does; it is a separate
        /// operation because it says why, and because a chain check can
        /// hold it to account: a pinned field must be one the new version
        /// still knows.
        public static func pinDefault(_ path: String, _ value: JSONValue) -> Operation {
            Operation(.pinDefault(path: path, value: value))
        }

        /// The escape hatch: an edit written as code against the whole
        /// document. `id` names it for machines (the export lists it, an
        /// issue quotes it); two customs with the same `id` compare equal.
        ///
        /// - Parameters:
        ///   - apply: Edits the document. Throws ``MigrationFailure`` if it
        ///     cannot, which draws a `migration_failed` issue.
        ///   - inverse: Turns a document of the new shape back into one of
        ///     the old, for ``Schema/migrationChainCheck()``. Without it the
        ///     check cannot test this step and says so.
        public static func custom(
            id: String,
            description: String = "",
            apply: @escaping @Sendable (inout JSONValue) throws(MigrationFailure) -> Void,
            inverse: (@Sendable (inout JSONValue) throws(MigrationFailure) -> Void)? = nil
        ) -> Operation {
            Operation(.custom(Custom(id: id, description: description, apply: apply, inverse: inverse)))
        }

        public var description: String {
            switch kind {
            case .rename(let path, let name): "rename \(path) to \(name)"
            case .move(let from, let to): "move \(from) to \(to)"
            case .delete(let path, _): "delete \(path)"
            case .setIfAbsent(let path, let value): "set \(path) to \(value.encodedString(style: .compact)) if absent"
            case .mapEnum(let path, let mapping):
                "map \(path): " + mapping.sorted { $0.key < $1.key }.map { "\($0.key) -> \($0.value)" }.joined(separator: ", ")
            case .pinDefault(let path, let value): "pin \(path) to \(value.encodedString(style: .compact))"
            case .custom(let custom): custom.description.isEmpty ? "custom \(custom.id)" : "custom \(custom.id): \(custom.description)"
            }
        }
    }

    /// An edit written as code; see ``Operation/custom(id:description:apply:inverse:)``.
    /// Equality and hashing look at the `id` alone, as for a custom constraint.
    public struct Custom: Sendable, Hashable {
        public var id: String
        public var description: String
        public var apply: @Sendable (inout JSONValue) throws(MigrationFailure) -> Void
        public var inverse: (@Sendable (inout JSONValue) throws(MigrationFailure) -> Void)?

        public init(
            id: String,
            description: String,
            apply: @escaping @Sendable (inout JSONValue) throws(MigrationFailure) -> Void,
            inverse: (@Sendable (inout JSONValue) throws(MigrationFailure) -> Void)?
        ) {
            self.id = id
            self.description = description
            self.apply = apply
            self.inverse = inverse
        }

        public static func == (lhs: Custom, rhs: Custom) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    public static func == (lhs: Migration, rhs: Migration) -> Bool {
        lhs.from == rhs.from && lhs.to == rhs.to && lhs.operations == rhs.operations
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(from)
        hasher.combine(to)
        hasher.combine(operations)
    }
}

/// Why an edit of a document could not be made: the target of a rename was
/// taken, a path runs through something that is not an object, or custom
/// code gave up. It becomes a `migration_failed` issue.
public struct MigrationFailure: Error, Sendable, Hashable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// What a document without a version key means.
public enum MissingVersion: Sendable, Hashable {
    /// It predates versioning: it is the oldest version any migration
    /// reads, or the current version if there are no migrations. Right for
    /// a format that gained its version key late.
    case oldest
    /// It is a hand-written file in the current format. Right for a
    /// configuration whose users are expected to write only what they
    /// change; the price is that a file written before the key existed is
    /// read as current and not migrated.
    case current
    /// It is invalid: ``IssueCode/missingKey``.
    case error
}

/// A schema's version, the history that leads to it, and how a document
/// states which version it is.
///
/// Declared on an object by `version:` and `migrations:`; this is the value
/// the node records, for exporters and for ``Schema/migrationChainCheck()``.
public struct Versioning: Sendable, Hashable {
    /// The version this schema describes and encodes.
    public var current: Int
    /// The reserved key that holds a document's version. No field may use it.
    public var key: String
    public var missing: MissingVersion
    /// The steps, in the order declared.
    public var migrations: [Migration]

    public init(current: Int, key: String = "version", missing: MissingVersion = .oldest, migrations: [Migration] = []) {
        self.current = current
        self.key = key
        self.missing = missing
        self.migrations = migrations
        precondition(current >= 1, "a version is a positive integer, not \(current)")
        var seen: Set<Int> = []
        for step in migrations {
            precondition(step.from >= 1 && step.to > step.from, "a migration goes from a version to a later one: \(step.from) to \(step.to)")
            precondition(step.to <= current, "a migration goes to version \(step.to), beyond the schema's version \(current)")
            precondition(seen.insert(step.from).inserted, "two migrations start from version \(step.from)")
        }
        // Every step must lead on until the current version, or a document
        // would be migrated to a dead end.
        for step in migrations where step.to < current {
            precondition(
                migrations.contains { $0.from == step.to },
                "the migration to version \(step.to) leads nowhere: nothing migrates from it")
        }
    }

    /// The oldest version a document may have and still be read.
    public var oldest: Int { migrations.map(\.from).min() ?? current }

    /// The step that reads `version`, if any.
    func step(from version: Int) -> Migration? {
        migrations.first { $0.from == version }
    }
}
