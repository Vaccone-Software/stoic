/// Why a value could not be set or removed at a path.
public enum JSONPathError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The step to the next component cannot be taken: the value at `path` is
    /// `found`, and a key needs an object (an index, an array). Nothing is
    /// made in its place: a string or a number someone wrote is not replaced
    /// by an object because a deeper setting asked for one.
    case blocked(path: JSONPath, found: JSONValue)
    /// The path ends at, or goes through, an element of an array that cannot
    /// be made or taken out: an array changes as one whole value (as in
    /// ``JSONChange``). An element that exists can be replaced; one past the
    /// end cannot be added, and none can be removed.
    case arrayElement(path: JSONPath)
    /// The path is the root, which cannot be removed: nothing would be left.
    case root

    public var description: String {
        switch self {
        case .blocked(let path, let found):
            "cannot go through \(path): it is \(found.kindName), and the path needs an object (for a key) or an array (for an index) there"
        case .arrayElement(let path): "\(path) is an element of an array, and arrays change as a whole"
        case .root: "the whole document cannot be removed"
        }
    }
}

extension JSONValue {
    // `value(at:)` is in JSONValue.swift.

    /// This value with `value` put at `path`.
    ///
    /// - A member that exists keeps its place, and a new one is appended.
    /// - **Objects on the way are made** where there is nothing, so setting
    ///   `$.web.routes["github.com"]` in `{}` gives the whole nest.
    /// - What is there that is not an object is never replaced to make room:
    ///   setting `$.scroll.speed` where `scroll` is `3` throws `.blocked` at
    ///   `$.scroll`. (`null` blocks too: it is a value someone wrote.)
    /// - An index replaces an element that exists; one past the end is
    ///   `.arrayElement`.
    /// - The root path gives `value`.
    ///
    /// - Parameters:
    ///   - value: What the path then holds.
    ///   - path: Where to put it.
    /// - Throws: ``JSONPathError``; the value is not changed.
    public func setting(_ value: JSONValue, at path: JSONPath) throws(JSONPathError) -> JSONValue {
        try Self.set(value, in: self, from: path.components[...], at: .root)
    }

    /// This value without what is at `path`.
    ///
    /// Removing what is not there (a missing key, a path through a value that
    /// is not an object, an index past the end) changes nothing, so it can be
    /// repeated.
    ///
    /// - Parameters:
    ///   - path: What to remove.
    ///   - pruning: Also remove each object that the removal left
    ///   empty, from the removed member's parent upward, so unsetting the last
    ///   of `{"web": {"routes": {"a.com": 1}}}` leaves `{}` and not
    ///   `{"web": {"routes": {}}}`. Never the root, and never past an array:
    ///   an object that is an element of an array stays, however empty. An
    ///   object that was already empty is not touched.
    /// - Throws: `.root` for the root path; `.arrayElement` when the path ends
    ///   at an element of an array, which cannot be taken out. The value is
    ///   not changed.
    public func removing(at path: JSONPath, pruning: Bool = false) throws(JSONPathError) -> JSONValue {
        guard let last = path.components.last else { throw .root }
        guard value(at: path) != nil else { return self }
        if case .index = last { throw .arrayElement(path: path) }
        return Self.remove(from: self, from: path.components[...], pruning: pruning)
    }

    private static func set(
        _ new: JSONValue, in value: JSONValue, from rest: ArraySlice<JSONPath.Component>, at path: JSONPath
    ) throws(JSONPathError) -> JSONValue {
        guard let component = rest.first else { return new }
        switch component {
        case .key(let key):
            guard case .object(var object) = value else { throw .blocked(path: path, found: value) }
            object[key] = try set(new, in: object[key] ?? .object(JSONObject()), from: rest.dropFirst(), at: path.appending(key: key))
            return .object(object)
        case .index(let index):
            guard case .array(var elements) = value else { throw .blocked(path: path, found: value) }
            guard elements.indices.contains(index) else { throw .arrayElement(path: path.appending(index: index)) }
            elements[index] = try set(new, in: elements[index], from: rest.dropFirst(), at: path.appending(index: index))
            return .array(elements)
        }
    }

    /// `value` with the member at `rest` removed. The caller has checked that
    /// the path exists and does not end at an array element.
    private static func remove(from value: JSONValue, from rest: ArraySlice<JSONPath.Component>, pruning: Bool) -> JSONValue {
        guard let component = rest.first else { return value }
        switch (component, value) {
        case (.key(let key), .object(var object)):
            if rest.count == 1 {
                object[key] = nil
            } else if let child = object[key] {
                let result = remove(from: child, from: rest.dropFirst(), pruning: pruning)
                if pruning, case .object(let left) = result, left.isEmpty, case .object(let before) = child, !before.isEmpty {
                    object[key] = nil
                } else {
                    object[key] = result
                }
            }
            return .object(object)
        case (.index(let index), .array(var elements)):
            elements[index] = remove(from: elements[index], from: rest.dropFirst(), pruning: pruning)
            return .array(elements)
        default:
            return value
        }
    }
}
