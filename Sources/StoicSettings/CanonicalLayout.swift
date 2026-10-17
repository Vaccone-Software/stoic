internal import StoicJSON
internal import StoicSchema

/// The byte-stable shape of a hand-edited settings file.
///
/// Two writers that hold the same value must write the same bytes: otherwise
/// an app and a command-line tool that edit one file churn it between them,
/// and a person who keeps it in a repository sees a diff for every save.
/// Sparse output already makes *which* members are written depend on the value
/// alone (the schema leaves out what equals its default). What is left is
/// *where* each goes, and how each number is spelt:
///
/// - Where the schema describes an object, its members are in the order the
///   schema declares its fields, the version key first; any others (the keys a
///   newer build added, carried from the file) follow alphabetically.
/// - Where it does not (a dictionary's entries, a `json` field, an unknown
///   key's value) members are alphabetical, compared as the canonical
///   encoding compares keys, all the way down.
/// - Arrays keep their order, and are walked for the objects in them.
/// - Numbers are written canonically (`1.0` is `1`, `1e3` is `1000`), so a
///   value a person wrote one way and a tool another is still one spelling.
enum CanonicalLayout {
    /// `value` with every object's members put in order, and every number in
    /// canonical form. `node` describes `value`; `nil` where nothing does.
    static func arranged(_ value: JSONValue, as node: SchemaNode?) -> JSONValue {
        switch value {
        case .number(let number):
            return .number(JSONNumber(lexeme: number.canonicalLexeme) ?? number)
        case .array(let elements):
            guard case .array(let element, _)? = resolved(node) else { return .array(elements.map { arranged($0, as: nil) }) }
            return .array(elements.map { arranged($0, as: element) })
        case .object(let object):
            return .object(arranged(object, as: node))
        case .null, .bool, .string:
            return value
        }
    }

    private static func arranged(_ object: JSONObject, as node: SchemaNode?) -> JSONObject {
        switch resolved(node) {
        case .object(let described)?:
            var order: [(key: String, node: SchemaNode?)] = []
            if let versioning = described.versioning { order.append((versioning.key, nil)) }
            order += described.fields.map { ($0.key, $0.node) }
            return arranged(object, declared: order, others: nil)
        case .dictionary(let valueNode, _)?:
            return arranged(object, declared: [], others: valueNode)
        case .union(let union)?:
            var order: [(key: String, node: SchemaNode?)] = [(union.discriminator, nil)]
            if let tag = object[union.discriminator]?.string, let chosen = union.cases.first(where: { $0.tag == tag }) {
                if !chosen.isFlat {
                    order.append((union.valueKey, chosen.node))
                } else if case .object(let payload)? = resolved(chosen.node) {
                    order += payload.fields.map { ($0.key, $0.node) }
                }
            }
            return arranged(object, declared: order, others: nil)
        default:
            return arranged(object, declared: [], others: nil)
        }
    }

    /// `object` with the `declared` keys first, in that order, then the rest
    /// alphabetically; `others` describes the values of the rest.
    private static func arranged(
        _ object: JSONObject, declared: [(key: String, node: SchemaNode?)], others: SchemaNode?
    ) -> JSONObject {
        var result = JSONObject()
        for (key, node) in declared {
            guard let value = object[key] else { continue }
            result[key] = arranged(value, as: node)
        }
        let rest = object.keys.filter { !result.contains(key: $0) }
            .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        for key in rest {
            if let value = object[key] { result[key] = arranged(value, as: others) }
        }
        return result
    }

    /// The node that says what the value is, seen through what only wraps it.
    private static func resolved(_ node: SchemaNode?) -> SchemaNode? {
        switch node {
        case .optional(let wrapped, _)?: resolved(wrapped)
        case .transformed(let transform)?: resolved(transform.base)
        case .lazy(_, let resolve)?: resolved(resolve())
        default: node
        }
    }
}
