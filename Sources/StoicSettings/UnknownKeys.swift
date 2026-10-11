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
