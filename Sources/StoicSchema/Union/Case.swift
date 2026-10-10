internal import StoicJSON

/// One alternative of a tagged union: the tag that names it, the schema of
/// what it carries, and how to move between the payload and the enumeration
/// that holds it.
///
///     enum Shape: Sendable, Equatable {
///         case circle(Circle)
///         case rect(Rect)
///         case point
///     }
///
///     extension Shape {
///         static let schema: Schema<Shape> = .union(discriminator: "type") {
///             Case("circle", Circle.schema, Shape.circle) { if case .circle(let c) = $0 { c } else { nil } }
///             Case("rect", Rect.schema, Shape.rect) { if case .rect(let r) = $0 { r } else { nil } }
///             Case("point", Shape.point) { if case .point = $0 { true } else { false } }
///         }
///     }
///
/// Swift has no way to go from an enumeration back to a case's payload
/// without a `switch`, so each case says it twice: how to build the
/// enumeration from a payload (usually the case's own name, which is a
/// function) and how to take a payload back out (a closure that returns
/// `nil` for every other case). The pair is the price of not needing a
/// macro; `@Schema` (StoicMacros) writes it.
public struct Case<Root: Sendable>: Sendable {
    let tag: String
    let doc: String?
    let node: SchemaNode
    /// Whether the payload's fields sit beside the discriminator (an
    /// object payload) or under a key of their own (anything else).
    let isFlat: Bool
    /// Reads the payload, given the union object without its discriminator
    /// (flat) or the value under the value key (keyed).
    let decode: @Sendable (JSONValue, inout DecodeState) -> Root?
    /// Writes the payload if `value` is this case: `nil` if it is another
    /// case, `.some(nil)` if the case has a payload that writes as nothing.
    let encode: @Sendable (Root, inout EncodeState) -> JSONValue??

    /// A case that carries a payload.
    ///
    /// An object payload is written *flat*: its fields sit beside the
    /// discriminator, `{"type": "circle", "radius": 5}`, which is how wire
    /// formats are written and how editors and JSON Schema validators
    /// expect them. Any other payload (a number, a string, an array) has no
    /// fields to sit among, so it is written under the union's value key,
    /// `{"type": "label", "value": "Hello"}`.
    ///
    /// - Parameters:
    ///   - tag: The discriminator's value for this case.
    ///   - schema: The payload's schema. For a flat case it must not declare
    ///     the discriminator as a field of its own.
    ///   - make: Builds the union from a payload: the case itself.
    ///   - doc: Documentation of the case.
    ///   - extract: The payload if the value is this case, otherwise `nil`.
    public init<Payload: Sendable>(
        _ tag: String,
        _ schema: Schema<Payload>,
        _ make: @escaping @Sendable (Payload) -> Root,
        doc: String? = nil,
        extract: @escaping @Sendable (Root) -> Payload?
    ) {
        var flat = false
        if case .object = schema.node { flat = true }
        self.tag = tag
        self.doc = doc
        node = schema.node
        isFlat = flat
        decode = { json, state in
            guard let payload = schema.decoder(json, &state) else { return nil }
            return make(payload)
        }
        encode = { value, state in
            guard let payload = extract(value) else { return nil }
            return .some(schema.encoder(payload, &state))
        }
    }

    /// A case that carries nothing: `{"type": "point"}`.
    ///
    /// - Parameters:
    ///   - tag: The discriminator's value for this case.
    ///   - value: The union value the tag stands for.
    ///   - doc: Documentation of the case.
    ///   - matches: Whether a value is this case.
    public init(
        _ tag: String,
        _ value: Root,
        doc: String? = nil,
        matches: @escaping @Sendable (Root) -> Bool
    ) {
        self.init(tag, Schema<Empty>.empty, { _ in value }, doc: doc, extract: { matches($0) ? Empty() : nil })
    }
}

/// The payload of a case that carries nothing.
struct Empty: Sendable {}

extension Schema where Value == Empty {
    /// An object with no fields: it rejects any key, so `{"type": "point",
    /// "radus": 1}` says `radus` is unknown.
    static var empty: Schema<Empty> {
        Schema<Empty>.object(Empty.self, default: Empty(), unknownKeys: .reject) {}
    }
}

/// Collects the `Case`s written in a union's body.
@resultBuilder
public struct CasesBuilder<Root: Sendable> {
    public static func buildExpression(_ element: Case<Root>) -> [Case<Root>] { [element] }
    public static func buildExpression(_ elements: [Case<Root>]) -> [Case<Root>] { elements }
    public static func buildBlock(_ parts: [Case<Root>]...) -> [Case<Root>] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [Case<Root>]?) -> [Case<Root>] { part ?? [] }
    public static func buildEither(first part: [Case<Root>]) -> [Case<Root>] { part }
    public static func buildEither(second part: [Case<Root>]) -> [Case<Root>] { part }
    public static func buildArray(_ parts: [[Case<Root>]]) -> [Case<Root>] { parts.flatMap { $0 } }
    public static func buildLimitedAvailability(_ part: [Case<Root>]) -> [Case<Root>] { part }
}
