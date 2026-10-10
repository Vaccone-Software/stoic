internal import StoicJSON

extension Migration {
    /// Applies the step to a document, edit by edit.
    func apply(to document: inout JSONValue) throws(MigrationFailure) {
        for operation in operations { try operation.apply(to: &document) }
    }

    /// What undoes this step, as operations to apply in order, or `nil` if
    /// some operation has no inverse. Used by the chain check to turn a
    /// generated current document into one that could have been written by
    /// the older release.
    func inverted() -> (operations: [Operation], gaps: [String])? {
        var inverse: [Operation] = []
        var gaps: [String] = []
        for operation in operations.reversed() {
            switch operation.inverse() {
            case .operation(let undo): inverse.append(undo)
            case .noEffect(let why): gaps.append(why)
            case .notInvertible: return nil
            }
        }
        return (inverse, gaps)
    }
}

extension Migration.Operation {
    /// What undoes an operation.
    enum Inverse {
        case operation(Migration.Operation)
        /// Nothing needs undoing, or nothing can be: the new document is
        /// also a possible old document. The reason is for the report.
        case noEffect(String)
        case notInvertible
    }

    func inverse() -> Inverse {
        switch kind {
        case .rename(let path, let name):
            var keys = PathEdit.split(path)
            guard let last = keys.last else { return .noEffect("rename of an empty path") }
            keys.removeLast()
            return .operation(.rename((keys + [name]).joined(separator: "."), to: last))
        case .move(let from, let to):
            return .operation(.move(to, to: from))
        case .delete(let path, let example):
            guard let example else { return .noEffect("`\(path)` was deleted and no example of its old value was given") }
            return .operation(.setIfAbsent(path, example))
        case .setIfAbsent(let path, _), .pinDefault(let path, _):
            // The old document may simply not have had the field.
            return .operation(.delete(path))
        case .mapEnum(let path, let mapping):
            var reverse: [String: String] = [:]
            for (old, new) in mapping {
                guard reverse.updateValue(old, forKey: new) == nil else { return .notInvertible }
            }
            return .operation(.mapEnum(path, reverse))
        case .custom(let custom):
            guard let inverse = custom.inverse else { return .notInvertible }
            return .operation(.custom(id: custom.id + " (inverse)", description: custom.description, apply: inverse))
        }
    }

    func apply(to document: inout JSONValue) throws(MigrationFailure) {
        if case .custom(let custom) = kind {
            try custom.apply(&document)
            return
        }
        guard case .object(var root) = document else { return }
        switch kind {
        case .rename(let path, let name):
            try PathEdit.rename(path, to: name, in: &root)
        case .move(let from, let to):
            try PathEdit.move(from, to: to, in: &root)
        case .delete(let path, _):
            PathEdit.remove(PathEdit.split(path)[...], from: &root)
        case .setIfAbsent(let path, let value), .pinDefault(let path, let value):
            let keys = PathEdit.split(path)
            if PathEdit.value(at: keys[...], in: root) == nil {
                try PathEdit.set(value, at: keys[...], in: &root)
            }
        case .mapEnum(let path, let mapping):
            let keys = PathEdit.split(path)
            if case .string(let old)? = PathEdit.value(at: keys[...], in: root), let new = mapping[old] {
                try PathEdit.set(.string(new), at: keys[...], in: &root, replacing: true)
            }
        case .custom:
            break
        }
        document = .object(root)
    }
}

/// Edits of a JSON object addressed by a path of keys.
enum PathEdit {
    static func split(_ path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    static func value(at keys: ArraySlice<String>, in object: JSONObject) -> JSONValue? {
        guard let first = keys.first, let next = object[first] else { return nil }
        if keys.count == 1 { return next }
        guard case .object(let child) = next else { return nil }
        return value(at: keys.dropFirst(), in: child)
    }

    /// Calls `body` on the object that holds the last key of `keys`'s
    /// parent path, creating objects on the way if `create`. Returns whether
    /// it found the object.
    @discardableResult
    private static func withParent(
        of keys: ArraySlice<String>,
        in object: inout JSONObject,
        create: Bool,
        _ body: (inout JSONObject, String) throws(MigrationFailure) -> Void
    ) throws(MigrationFailure) -> Bool {
        guard let first = keys.first else { return false }
        if keys.count == 1 {
            try body(&object, first)
            return true
        }
        switch object[first] {
        case .object(var child)?:
            let found = try withParent(of: keys.dropFirst(), in: &child, create: create, body)
            if found { object[first] = .object(child) }
            return found
        case nil where create:
            var child = JSONObject()
            let found = try withParent(of: keys.dropFirst(), in: &child, create: true, body)
            if found { object[first] = .object(child) }
            return found
        case nil:
            return false
        case .some:
            if create { throw MigrationFailure("`\(first)` holds a value that is not an object, so nothing can be put inside it") }
            return false
        }
    }

    static func remove(_ keys: ArraySlice<String>, from object: inout JSONObject, pruning: Bool = false) {
        _ = try? withParent(of: keys, in: &object, create: false) { parent, key in parent[key] = nil }
        // A move out of `a.b` should not leave `a` behind as an empty husk.
        if pruning, keys.count > 1, case .object(let parent)? = value(at: keys.dropLast(), in: object), parent.isEmpty {
            remove(keys.dropLast(), from: &object, pruning: true)
        }
    }

    static func set(
        _ value: JSONValue,
        at keys: ArraySlice<String>,
        in object: inout JSONObject,
        replacing: Bool = false
    ) throws(MigrationFailure) {
        try withParent(of: keys, in: &object, create: true) { (parent: inout JSONObject, key: String) throws(MigrationFailure) in
            if !replacing, parent[key] != nil { throw MigrationFailure("`\(key)` is already there") }
            parent[key] = value
        }
    }

    /// Renames a key without moving it: members keep their order.
    static func rename(_ path: String, to name: String, in object: inout JSONObject) throws(MigrationFailure) {
        let keys = split(path)
        try withParent(of: keys[...], in: &object, create: false) { (parent: inout JSONObject, key: String) throws(MigrationFailure) in
            guard parent[key] != nil, key != name else { return }
            guard parent[name] == nil else {
                throw MigrationFailure("cannot rename `\(path)` to `\(name)`: `\(name)` is already there")
            }
            parent = JSONObject(
                parent.map { member in
                    ExactKey(member.key) == ExactKey(key) ? JSONObject.Member(key: name, value: member.value) : member
                })
        }
    }

    static func move(_ from: String, to: String, in object: inout JSONObject) throws(MigrationFailure) {
        let source = split(from)
        guard let moved = value(at: source[...], in: object) else { return }
        let target = split(to)
        if value(at: target[...], in: object) != nil {
            throw MigrationFailure("cannot move `\(from)` to `\(to)`: `\(to)` is already there")
        }
        try set(moved, at: target[...], in: &object)
        remove(source[...], from: &object, pruning: true)
    }
}
