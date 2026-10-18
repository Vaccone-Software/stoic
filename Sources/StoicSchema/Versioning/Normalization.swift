public import StoicJSON

/// Tidying a document on every read, with no version number: the spellings a
/// file people edit has accumulated, brought to the ones the schema declares.
///
///     Settings.schema.normalizing(
///         .rename("hyper", to: "searcher"),                // an old key; the new one wins if both are there
///         .mapEnum("mode", ["raw-hyper": "hyper"]),        // an old spelling of a value
///         .custom(id: "profiles", description: "…") { document in … },
///         retired: ["old-flag", "observations.legacy"])    // read and ignored, never written back
///
/// A ``Migration`` is the other tool: it needs an integer version, runs once
/// as a file crosses it, and refuses a rename onto a key that is taken. A
/// normalization is for a document that never had a version and never will,
/// whose reader has always forgiven its past: it runs on the raw JSON before
/// anything is decoded, **on every read**, and so must be *idempotent*:
/// applying it to its own result changes nothing. The declarative operations
/// are idempotent by construction (a rename that finds its target taken drops
/// the old key, because the key the file's newer writer used is the one that
/// counts; a `mapEnum` whose targets are also its sources would not be, and
/// traps where it is written); a ``Operation/custom(id:description:apply:)``
/// is the author's to keep so, and ``Schema/normalized(_:)`` is how a test
/// checks it: `normalized(normalized(x)) == normalized(x)`.
///
/// Normalization is silent. It raises no issue (the file may be as it has
/// always been) and writes nothing on load; a store that writes the file back
/// carries the *normalized* document's unknown keys, so a key the
/// normalization renamed or retired is not written back in its old place.
///
/// Paths are keys separated by dots, from the object the normalization is
/// declared on (`network.hosts`); a key that contains a dot needs a custom
/// operation. A path that is not in the document is skipped.
public struct Normalization: Sendable, Hashable {
    /// The operations, applied in order.
    public var operations: [Operation]

    /// Paths that mean nothing any more: removed after the operations, so
    /// they draw no `unknown_key` warning, and so nothing carries them back
    /// into a file on the next write. For a key an earlier release read and
    /// the current one has no use for.
    public var retired: [String]

    public init(_ operations: [Operation] = [], retired: [String] = []) {
        self.operations = operations
        self.retired = retired
        for path in retired {
            precondition(
                !PathEdit.split(path).contains(""), "a retired path is keys joined by dots, not `\(path)`")
        }
    }

    /// One edit of the document. Unlike a ``Migration/Operation`` none fails
    /// because its target is taken: the target that exists wins.
    public struct Operation: Sendable, Hashable, CustomStringConvertible {
        /// What the operation does, as data.
        public enum Kind: Sendable, Hashable {
            /// Gives the value at `path` a new last key `name`, in the same
            /// place. If `name` is already there, that value is kept and the
            /// old key is dropped.
            case rename(path: String, name: String)
            /// Takes the value at `from` to `to`, creating the objects on the
            /// way, and prunes what it leaves empty. If `to` is already
            /// there, that value is kept and `from` is dropped.
            case move(from: String, to: String)
            /// Removes the value at `path`.
            case delete(path: String)
            /// Sets `path` to `value` unless it is present.
            case setIfAbsent(path: String, value: JSONValue)
            /// Replaces the string at `path` by its image under `mapping`;
            /// strings the mapping does not mention are left alone.
            case mapEnum(path: String, mapping: [String: String])
            /// An edit only code can state.
            case custom(Custom)
        }

        public var kind: Kind

        public init(_ kind: Kind) {
            self.kind = kind
        }

        /// Renames the value at `path` to `name`, keeping a value already at
        /// `name`: `.rename("hyper", to: "searcher")`, or
        /// `.rename("observations.enabled", to: "isEnabled")` for a nested key.
        public static func rename(_ path: String, to name: String) -> Operation {
            Operation(.rename(path: path, name: name))
        }

        /// Moves the value at `from` to `to`, keeping a value already there:
        /// `.move("hosts", to: "network.hosts")`. Neither path may lie inside
        /// the other (it would put the value inside itself), which traps here.
        public static func move(_ from: String, to: String) -> Operation {
            let source = PathEdit.split(from)
            let target = PathEdit.split(to)
            precondition(
                !source.starts(with: target) && !target.starts(with: source),
                "a move from `\(from)` to `\(to)` has one path inside the other, and would delete what it moves")
            return Operation(.move(from: from, to: to))
        }

        /// Removes the value at `path`.
        public static func delete(_ path: String) -> Operation {
            Operation(.delete(path: path))
        }

        /// Sets `path` to `value` if the document has none there.
        public static func setIfAbsent(_ path: String, _ value: JSONValue) -> Operation {
            Operation(.setIfAbsent(path: path, value: value))
        }

        /// Renames the values of an enumeration: `.mapEnum("mode", ["raw-hyper": "hyper"])`.
        ///
        /// A spelling that is both mapped and the image of another would be
        /// mapped again on the next read, which a normalization must not do;
        /// that is a mistake in the declaration, and it traps here.
        public static func mapEnum(_ path: String, _ mapping: [String: String]) -> Operation {
            for (old, new) in mapping where old != new {
                precondition(
                    mapping[new] == nil || mapping[new] == new,
                    "mapEnum(\(path)): `\(new)` is both a result and a spelling that is mapped, so the map is not idempotent")
            }
            return Operation(.mapEnum(path: path, mapping: mapping))
        }

        /// The escape hatch: an edit written as code against the document
        /// the normalization is declared on (the object, not the file). `id`
        /// names it for machines; two customs with the same `id` compare
        /// equal. It must be idempotent, and a path it moves is not followed
        /// by the positions of issues (see ``Schema/normalizing(_:)``).
        ///
        /// - Parameters:
        ///   - id: Names the edit for machines.
        ///   - description: What the edit does, in words.
        ///   - apply: Edits the object. Throws ``MigrationFailure`` if it
        ///     cannot, which draws a `normalization_failed` issue.
        public static func custom(
            id: String,
            description: String = "",
            apply: @escaping @Sendable (inout JSONValue) throws(MigrationFailure) -> Void
        ) -> Operation {
            Operation(.custom(Custom(id: id, description: description, apply: apply)))
        }

        public var description: String {
            switch kind {
            case .rename(let path, let name): "rename \(path) to \(name)"
            case .move(let from, let to): "move \(from) to \(to)"
            case .delete(let path): "delete \(path)"
            case .setIfAbsent(let path, let value): "set \(path) to \(value.encodedString(style: .compact)) if absent"
            case .mapEnum(let path, let mapping):
                "map \(path): " + mapping.sorted { $0.key < $1.key }.map { "\($0.key) -> \($0.value)" }.joined(separator: ", ")
            case .custom(let custom): custom.description.isEmpty ? "custom \(custom.id)" : "custom \(custom.id): \(custom.description)"
            }
        }
    }

    /// An edit written as code; see ``Operation/custom(id:description:apply:)``.
    /// Equality and hashing look at the `id` alone, as for a custom constraint.
    public struct Custom: Sendable, Hashable {
        public var id: String
        public var description: String
        public var apply: @Sendable (inout JSONValue) throws(MigrationFailure) -> Void

        public init(
            id: String, description: String,
            apply: @escaping @Sendable (inout JSONValue) throws(MigrationFailure) -> Void
        ) {
            self.id = id
            self.description = description
            self.apply = apply
        }

        public static func == (lhs: Custom, rhs: Custom) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// `document` with the operations applied, then the retired paths removed;
    /// a value that is not an object is returned as it was. Pure, and
    /// idempotent for the declarative operations: a test of a normalization
    /// with a custom operation checks `applying(to: applying(to: x)) == applying(to: x)`.
    public func applying(to document: JSONValue) throws(MigrationFailure) -> JSONValue {
        var result = document
        _ = try apply(to: &result)
        return result
    }
}

extension Normalization {
    /// ``applying(to:)``, or `nil` if an operation fails.
    func normalizedOrNil(_ document: JSONValue) -> JSONValue? {
        var result = document
        do throws(MigrationFailure) {
            _ = try apply(to: &result)
        } catch {
            return nil
        }
        return result
    }
}

/// A value the normalization moved: the keys it was at, and the keys it is at.
/// What lets an issue about the moved value point at the text where it was.
struct Relocation: Sendable, Hashable {
    var from: [String]
    var to: [String]
}

extension Normalization {
    /// Applies the operations and removes the retired paths, returning where
    /// declarative operations moved values.
    func apply(to document: inout JSONValue) throws(MigrationFailure) -> [Relocation] {
        guard case .object(var root) = document else { return [] }
        var moved: [Relocation] = []
        // A custom operation sees, and may replace, the whole document: hand it
        // over, and take back what it leaves.
        for operation in operations {
            if case .custom(let custom) = operation.kind {
                var whole = JSONValue.object(root)
                try custom.apply(&whole)
                guard case .object(let edited) = whole else {
                    throw MigrationFailure("custom operation `\(custom.id)` replaced the document by something that is not an object")
                }
                root = edited
                continue
            }
            if let relocation = try operation.apply(to: &root) { moved.append(relocation) }
        }
        for path in retired { PathEdit.remove(PathEdit.split(path)[...], from: &root) }
        document = .object(root)
        return moved
    }
}

extension Normalization.Operation {
    /// Applies a declarative operation; returns the move it made, if any.
    fileprivate func apply(to root: inout JSONObject) throws(MigrationFailure) -> Relocation? {
        switch kind {
        case .rename(let path, let name):
            let keys = PathEdit.split(path)
            guard try PathEdit.renameKeepingExisting(path, to: name, in: &root) else { return nil }
            return Relocation(from: keys, to: Array(keys.dropLast()) + [name])
        case .move(let from, let to):
            let source = PathEdit.split(from)
            let target = PathEdit.split(to)
            guard let moved = PathEdit.value(at: source[...], in: root) else { return nil }
            if PathEdit.value(at: target[...], in: root) != nil {
                PathEdit.remove(source[...], from: &root, pruning: true)
                return nil
            }
            try PathEdit.set(moved, at: target[...], in: &root)
            PathEdit.remove(source[...], from: &root, pruning: true)
            return Relocation(from: source, to: target)
        case .delete(let path):
            PathEdit.remove(PathEdit.split(path)[...], from: &root)
        case .setIfAbsent(let path, let value):
            let keys = PathEdit.split(path)
            if PathEdit.value(at: keys[...], in: root) == nil { try PathEdit.set(value, at: keys[...], in: &root) }
        case .mapEnum(let path, let mapping):
            let keys = PathEdit.split(path)
            if case .string(let old)? = PathEdit.value(at: keys[...], in: root), let new = mapping[old] {
                try PathEdit.set(.string(new), at: keys[...], in: &root, replacing: true)
            }
        case .custom:
            break
        }
        return nil
    }
}

extension PathEdit {
    /// Renames a key without moving it, unless `name` is taken: then the key
    /// that is there stays and the old one is dropped. Returns whether the
    /// value took the new name.
    static func renameKeepingExisting(
        _ path: String, to name: String, in object: inout JSONObject
    ) throws(MigrationFailure) -> Bool {
        let keys = split(path)
        guard let last = keys.last else { return false }
        let parentKeys = Array(keys.dropLast())
        var parent: JSONObject
        if parentKeys.isEmpty {
            parent = object
        } else if case .object(let found)? = value(at: parentKeys[...], in: object) {
            parent = found
        } else {
            return false
        }
        guard parent[last] != nil, ExactKey(last) != ExactKey(name) else { return false }
        var renamed = false
        if parent[name] != nil {
            parent[last] = nil
        } else {
            parent = JSONObject(
                parent.map { member in
                    ExactKey(member.key) == ExactKey(last) ? JSONObject.Member(key: name, value: member.value) : member
                })
            renamed = true
        }
        if parentKeys.isEmpty {
            object = parent
        } else {
            try set(.object(parent), at: parentKeys[...], in: &object, replacing: true)
        }
        return renamed
    }
}

extension SchemaNode {
    /// `value` as the schema reads it: every object's normalization applied,
    /// in the objects the schema describes (fields of objects, however
    /// nested, through optionals, arrays, dictionaries and transparent
    /// wrappers; not a union's payloads). An object whose normalization fails
    /// is left as it was: reading it reports why.
    func normalizing(_ value: JSONValue) -> JSONValue {
        switch self {
        case .object(let object):
            guard case .object = value else { return value }
            let result = object.normalization?.normalizedOrNil(value) ?? value
            guard case .object(var members) = result else { return result }
            for field in object.fields {
                for key in [field.key] + field.aliases {
                    guard let child = members[key] else { continue }
                    members[key] = field.node.normalizing(child)
                    break
                }
            }
            return .object(members)
        case .optional(let wrapped, _):
            return wrapped.normalizing(value)
        case .transformed(let transform):
            return transform.base.normalizing(value)
        case .array(let element, _):
            guard case .array(let items) = value else { return value }
            return .array(items.map { element.normalizing($0) })
        case .dictionary(let element, _):
            guard case .object(let members) = value else { return value }
            var result = members
            for member in members { result[member.key] = element.normalizing(member.value) }
            return .object(result)
        case .lazy(_, let resolve):
            return resolve().normalizing(value)
        case .boolean, .integer, .number, .string, .enumeration, .integerEnumeration, .json, .union:
            return value
        }
    }
}
