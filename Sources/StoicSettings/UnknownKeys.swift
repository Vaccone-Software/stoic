internal import StoicJSON
internal import StoicSchema

/// Carrying keys the schema does not declare from the document that was
/// loaded into the one about to be written.
///
/// A schema writes only what it declares, so a settings file saved by an
/// older build would lose a field a newer build added, the next time the
/// older build saved anything. The store keeps the loaded document and puts
/// every key the schema does not declare back, with its value untouched.
///
/// Objects nested directly in a declared field are handled the same way
/// (an optional one too). The limit is arrays, dictionaries, unions and
/// transformed values: their elements cannot be matched to the loaded
/// document's, so unknown keys inside them are not carried.
enum UnknownKeys {
    /// `encoded` with every key of `loaded` that `node` does not declare put
    /// back. A key `encoded` already has is left alone: what the schema
    /// wrote wins.
    static func carrying(_ loaded: JSONValue, into encoded: JSONValue, node: SchemaNode) -> JSONValue {
        var result = encoded
        merge(loaded, into: &result, node: node)
        return result
    }

    private static func merge(_ loaded: JSONValue, into encoded: inout JSONValue, node: SchemaNode) {
        switch node {
        case .optional(let wrapped, _):
            merge(loaded, into: &encoded, node: wrapped)
        case .object(let object):
            guard case .object(let loadedObject) = loaded, case .object(var out) = encoded else { return }
            var declared: Set<String> = []
            for field in object.fields {
                declared.insert(field.key)
                declared.formUnion(field.aliases)
            }
            if let versioning = object.versioning { declared.insert(versioning.key) }

            for member in loadedObject where !declared.contains(member.key) && out[member.key] == nil {
                out[member.key] = member.value
            }
            for field in object.fields {
                guard let loadedChild = loadedObject[field.key], holdsObject(field.node) else { continue }
                // Sparse output leaves a nested object out when it is all
                // defaults; its unknown keys still need somewhere to live.
                var child = out[field.key] ?? .object(JSONObject())
                merge(loadedChild, into: &child, node: field.node)
                if out[field.key] != nil || child.object?.isEmpty == false { out[field.key] = child }
            }
            encoded = .object(out)
        default:
            return
        }
    }

    private static func holdsObject(_ node: SchemaNode) -> Bool {
        switch node {
        case .object: true
        case .optional(let wrapped, _): holdsObject(wrapped)
        default: false
        }
    }
}

/// A field the load repaired (its value was one the schema does not accept,
/// so the default stood in), with the value the file held.
///
/// A newer build may have written that value: a range it widened, an
/// enumeration case it added, without a new version. Until the app changes
/// the field, every write puts the file's value back, so an older build
/// never destroys it by saving something else.
struct RepairedField: Sendable, Equatable {
    /// Where the field is. Only paths through objects are carried.
    let path: JSONPath
    /// What the file held there.
    let original: JSONValue
    /// The repaired value, fully encoded: while the value about to be written
    /// still encodes to this, the app has not changed the field.
    let repairedTo: JSONValue?

    /// The fields of `issues` that were repaired, with what `document` held
    /// for each and what `repaired` (the full encoding of the decoded value)
    /// holds now.
    static func found(in issues: [Issue], document: JSONValue?, repaired: JSONValue) -> [RepairedField] {
        guard let document else { return [] }
        return issues.filter { $0.severity == .repaired }.compactMap { issue in
            guard issue.path.components.allSatisfy({ if case .key = $0 { true } else { false } }),
                  let original = document.value(at: issue.path) else { return nil }
            return RepairedField(path: issue.path, original: original, repairedTo: repaired.value(at: issue.path))
        }
    }

    /// `encoded` with the file's value put back for each field in `fields`
    /// that `full` (the value being written, fully encoded) has not changed,
    /// and the fields so carried.
    static func restoring(_ fields: [RepairedField], into encoded: JSONValue, full: JSONValue) -> (JSONValue, [RepairedField]) {
        var result = encoded
        var carried: [RepairedField] = []
        for field in fields where full.value(at: field.path) == field.repairedTo {
            if let restored = result.setting(field.original, at: field.path) {
                result = restored
                carried.append(field)
            }
        }
        return (result, carried)
    }
}

extension JSONValue {
    /// The value at `path`, if there is one.
    func value(at path: JSONPath) -> JSONValue? {
        var node = self
        for component in path.components {
            switch component {
            case .key(let key):
                guard let next = node.object?[key] else { return nil }
                node = next
            case .index(let index):
                guard case .array(let elements) = node, elements.indices.contains(index) else { return nil }
                node = elements[index]
            }
        }
        return node
    }

    /// This value with `value` at `path`, a path of object keys, making the
    /// objects on the way (sparse output leaves out one that is all defaults);
    /// `nil` if something on the way is not an object.
    func setting(_ value: JSONValue, at path: JSONPath) -> JSONValue? {
        guard let first = path.components.first else { return value }
        guard case .key(let key) = first, case .object(var object) = self else { return nil }
        let rest = JSONPath(Array(path.components.dropFirst()))
        guard let child = (object[key] ?? .object(JSONObject())).setting(value, at: rest) else { return nil }
        object[key] = child
        return .object(object)
    }
}
