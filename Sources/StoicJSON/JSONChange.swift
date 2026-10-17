/// One difference between two JSON values, at the deepest place that holds it.
///
/// An app that lets people change settings wants to say what changed, and to
/// take it back: a history with one line per edit, and an undo that restores
/// that line alone. ``between(_:_:)`` finds the changes from one document to
/// the next, and ``JSONValue/applying(_:overwriting:)`` makes (or, with
/// ``inverted``, unmakes) one of them, so a history is a list of changes and
/// undo is an application.
///
///     let changes = JSONChange.between(before, after)
///     // [$.scrollSpeed: 600 -> 900, $.theme: added "dark"]
///     let undone = try after.applyingAll(changes.reversed().map(\.inverted))   // == before
///
/// ## What a change is
///
/// - Objects are compared member by member, and only while both sides are
///   objects: a change is the deepest path at which the two values differ.
/// - A member present on one side only is one change at that member, with
///   the whole value that was added or removed (`old` or `new` is `nil`).
///   Removing `{"a": {"b": 1, "c": 2}}`'s `a` is one change, not two.
/// - **Arrays are leaves.** Two arrays that differ are one change holding
///   both whole arrays. Matching elements of two arrays is a guess (inserted
///   at the front, or every element changed?), and a settings history that
///   guessed wrong would undo something the person never did. An array is
///   written by the app or the person as a whole value, so it changes as one.
/// - A value that changes kind (a number that became a string, a string that
///   became an object) is one change at that path.
/// - Changes come in the order of their paths' keys, compared as the
///   canonical encoding compares them, so two equal pairs of values give the
///   same changes whatever order their members were written in.
public struct JSONChange: Sendable, Hashable, CustomStringConvertible {
    /// Where the change is. The root path means the two values differ as
    /// wholes (they are not both objects).
    public var path: JSONPath

    /// The value before; `nil` if there was none (the change adds one).
    public var old: JSONValue?

    /// The value after; `nil` if there is none (the change removes one).
    public var new: JSONValue?

    public init(path: JSONPath, old: JSONValue?, new: JSONValue?) {
        self.path = path
        self.old = old
        self.new = new
    }

    /// The change that undoes this one: before and after swapped.
    public var inverted: JSONChange {
        JSONChange(path: path, old: new, new: old)
    }

    /// `$.a.b: 1 -> 2`, `$.c: added "x"`, `$.d: removed 3`. Values are
    /// shown in compact JSON, so a long one makes a long line.
    public var description: String {
        func shown(_ value: JSONValue) -> String { value.encodedString(style: .compact) }
        switch (old, new) {
        case (let old?, let new?): return "\(path): \(shown(old)) -> \(shown(new))"
        case (nil, let new?): return "\(path): added \(shown(new))"
        case (let old?, nil): return "\(path): removed \(shown(old))"
        case (nil, nil): return "\(path): nothing"
        }
    }

    // MARK: Finding changes

    /// The changes that turn `old` into `new`: empty when they are equal.
    ///
    /// Applying them to `old`, in order, gives `new` (``JSONValue/applying(_:overwriting:)``).
    public static func between(_ old: JSONValue, _ new: JSONValue) -> [JSONChange] {
        var changes: [JSONChange] = []
        collect(old, new, at: .root, into: &changes)
        return changes
    }

    private static func collect(_ old: JSONValue, _ new: JSONValue, at path: JSONPath, into changes: inout [JSONChange]) {
        guard case .object(let before) = old, case .object(let after) = new else {
            if old != new { changes.append(JSONChange(path: path, old: old, new: new)) }
            return
        }
        // Objects ignore the order of their members, so the order of the
        // changes must not depend on it either.
        var keys = before.keys
        keys.append(contentsOf: after.keys.filter { !before.contains(key: $0) })
        keys.sort { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for key in keys {
            let member = path.appending(key: key)
            switch (before[key], after[key]) {
            case (let was?, let now?): collect(was, now, at: member, into: &changes)
            case (let was?, nil): changes.append(JSONChange(path: member, old: was, new: nil))
            case (nil, let now?): changes.append(JSONChange(path: member, old: nil, new: now))
            case (nil, nil): break
            }
        }
    }

    // MARK: Failing to apply

    /// Why a change could not be applied.
    public enum ApplyError: Error, Sendable, Hashable, CustomStringConvertible {
        /// The value at `path` is not the one the change replaces: `found` is
        /// what is there, `nil` for nothing. Only checked unless the change
        /// is applied with `overwriting`.
        case conflict(path: JSONPath, found: JSONValue?)
        /// The step to `path` cannot be taken: the value before it is not the
        /// object (or array) the step needs, the key is missing where the
        /// change has to go through it, or the index is past the array's end.
        case blocked(path: JSONPath)
        /// The change adds or removes an element of an array at `path`, which
        /// a change cannot express: an array changes as one whole value.
        case arrayElement(path: JSONPath)
        /// The change removes the whole value, which would leave nothing.
        case removesRoot

        public var description: String {
            switch self {
            case .conflict(let path, let found):
                "the value at \(path) is " + (found.map { $0.encodedString(style: .compact) } ?? "missing") + ", not the one the change replaces"
            case .blocked(let path): "cannot reach \(path): what leads to it is not there, or not the right kind of value"
            case .arrayElement(let path): "\(path) is an element of an array, and arrays change as a whole"
            case .removesRoot: "a change cannot remove the whole document"
            }
        }
    }
}

extension JSONValue {
    /// This value with `change` made.
    ///
    /// - Parameters:
    ///   - change: What to set at ``JSONChange/path`` (``JSONChange/new``, or
    ///     remove the member if that is `nil`).
    ///   - overwriting: By default the value now at the path must be the one
    ///     the change replaces (``JSONChange/old``, or nothing), so undoing an
    ///     edit that has since been changed again is a ``JSONChange/ApplyError/conflict(path:found:)``
    ///     for the app to decide, not a silent overwrite. With `overwriting`
    ///     the change is made whatever is there, and the objects on the way
    ///     are created if they are missing; removing what is not there does
    ///     nothing.
    /// - Throws: ``JSONChange/ApplyError``. The value is not changed.
    public func applying(_ change: JSONChange, overwriting: Bool = false) throws(JSONChange.ApplyError) -> JSONValue {
        try JSONChangeApplier(change: change, overwriting: overwriting).apply(to: self, from: change.path.components[...], at: .root)
    }

    /// This value with each of `changes` made in order, as one
    /// ``applying(_:overwriting:)`` after another. If one throws, none is applied.
    public func applyingAll(
        _ changes: some Sequence<JSONChange>, overwriting: Bool = false
    ) throws(JSONChange.ApplyError) -> JSONValue {
        var result = self
        for change in changes { result = try result.applying(change, overwriting: overwriting) }
        return result
    }
}

/// Walks a change's path down a value and makes it where the path ends.
private struct JSONChangeApplier {
    let change: JSONChange
    let overwriting: Bool

    /// `value` with the change made at `rest` below it; `at` is where `value` is.
    func apply(
        to value: JSONValue, from rest: ArraySlice<JSONPath.Component>, at path: JSONPath
    ) throws(JSONChange.ApplyError) -> JSONValue {
        guard let component = rest.first else {
            // The path ends here: `value` is what the change replaces.
            guard let new = change.new else { throw .removesRoot }
            try check(value, at: path)
            return new
        }
        let step: JSONPath
        let isLast = rest.count == 1
        switch component {
        case .key(let key):
            step = path.appending(key: key)
            guard case .object(var object) = value else { throw .blocked(path: step) }
            if isLast {
                try check(object[key], at: step)
                object[key] = change.new
                return .object(object)
            }
            guard let child = try descendant(object[key], at: step) else { return value }
            object[key] = try apply(to: child, from: rest.dropFirst(), at: step)
            return .object(object)
        case .index(let index):
            step = path.appending(index: index)
            guard case .array(var elements) = value, elements.indices.contains(index) else {
                // Past the end of an array, a change that would put an element
                // there is the one an array cannot take.
                if case .array = value, isLast, change.old == nil { throw .arrayElement(path: step) }
                throw .blocked(path: step)
            }
            if isLast {
                guard change.old != nil, let new = change.new else { throw .arrayElement(path: step) }
                try check(elements[index], at: step)
                elements[index] = new
                return .array(elements)
            }
            elements[index] = try apply(to: elements[index], from: rest.dropFirst(), at: step)
            return .array(elements)
        }
    }

    /// The value the path goes on through, or a fresh object if `overwriting`
    /// is making the way; `nil` when there is nothing to remove from.
    private func descendant(_ child: JSONValue?, at step: JSONPath) throws(JSONChange.ApplyError) -> JSONValue? {
        if let child { return child }
        guard overwriting else { throw .blocked(path: step) }
        // Removing what is not there changes nothing, and must not leave an
        // empty object where there was none.
        return change.new == nil ? nil : .object(JSONObject())
    }

    private func check(_ found: JSONValue?, at path: JSONPath) throws(JSONChange.ApplyError) {
        guard overwriting || found == change.old else { throw .conflict(path: path, found: found) }
    }
}
