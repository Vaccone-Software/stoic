public import StoicJSON

extension SchemaNode {
    /// What a dotted address needs to know of this node: which levels hold
    /// fixed keys and which hold the person's, for
    /// `JSONPath(address:shape:)` (StoicJSON).
    ///
    /// - An object's fields are fixed keys (aliases are not: an address names
    ///   the key the schema writes), a dictionary's keys are free, an array
    ///   is read by index, and every other node holds nothing below it.
    /// - What only wraps a value (an optional, a transformed value) is seen
    ///   through, and a recursive schema is read as far as the address goes.
    /// - A tagged union is read as the object holding the discriminator and,
    ///   from each case in declaration order, the fields of a flat payload or
    ///   the value key: the address does not say which case it means. Where
    ///   two cases declare the same key, the first one's shape is used.
    public var pathShape: JSONPath.Shape {
        switch self {
        case .boolean, .integer, .number, .string, .enumeration, .integerEnumeration, .json:
            return .value
        case .array(let element, _):
            return .elements(element.pathShape)
        case .dictionary(let value, _):
            return .freeKeys(value.pathShape)
        case .optional(let wrapped, _):
            return wrapped.pathShape
        case .transformed(let transform):
            return transform.base.pathShape
        case .lazy(_, let resolve):
            return .deferred { resolve().pathShape }
        case .object(let object):
            return .fields(Dictionary(object.fields.map { ($0.key, $0.node.pathShape) }, uniquingKeysWith: { first, _ in first }))
        case .union(let union):
            var fields: [String: JSONPath.Shape] = [union.discriminator: .value]
            for entry in union.cases {
                if entry.isFlat {
                    guard case .object(let payload) = entry.node else { continue }
                    for field in payload.fields where fields[field.key] == nil { fields[field.key] = field.node.pathShape }
                } else if fields[union.valueKey] == nil {
                    fields[union.valueKey] = entry.node.pathShape
                }
            }
            return .fields(fields)
        }
    }
}

extension Schema {
    /// The path a dotted address names in a document of this schema, where a
    /// key of a dictionary may contain dots (`web.routes.github.com` is the
    /// key `github.com` of `routes`): see `JSONPath(address:shape:)` in StoicJSON.
    /// `nil` for an address with an empty segment.
    ///
    /// Building the shape walks the schema, so for many addresses keep
    /// `node.pathShape` and read each with `JSONPath(address:shape:)`.
    public func path(forAddress address: String) -> JSONPath? {
        JSONPath(address: address, shape: node.pathShape)
    }
}
