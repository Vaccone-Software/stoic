public import StoicJSON

/// What a tagged union becomes when the server sends a tag it has never
/// heard of: the answer to "I do not know that one", chosen by the caller.
///
/// A closed union is the right default, because a tag that names no case is a
/// mistake worth reporting. A client of someone else's API cannot afford it:
/// the server adds a `case` in a release the client has not shipped yet, and
/// every response that carries it fails to decode, the ones that are
/// otherwise fine with it. So a union may name one case of its own as the
/// answer. Decoding then succeeds, with an ``IssueCode/unknownCase`` warning
/// at the discriminator (the same warning an enumeration raises, with the
/// nearest known tag), and the payload is not read at all: nothing is known
/// about its shape.
///
///     enum Event: Sendable, Equatable {
///         case created(Created)
///         case deleted
///         case unknown(tag: String, payload: JSONObject)
///     }
///
///     static let schema: Schema<Event> = .union(
///         unknown: .keepingPayload(Event.unknown) { if case .unknown(let tag, let payload) = $0 { (tag, payload) } else { nil } }
///     ) {
///         Case("created", Created.schema, Event.created) { if case .created(let c) = $0 { c } else { nil } }
///         Case("deleted", Event.deleted) { if case .deleted = $0 { true } else { false } }
///     }
///
/// How much of the unknown case is kept decides how it is written back. A
/// value that passes through the client (read, changed elsewhere, sent
/// again) comes out as it went in only if the case holds the whole of it;
/// the three forms below differ in exactly that.
public struct UnknownTag<Root: Sendable>: Sendable {
    /// The unknown case's name: what the warning says the tag was read as, and
    /// what a plain unknown case is written as.
    let name: String
    let read: @Sendable (_ tag: String, _ payload: JSONObject) -> Root
    let write: @Sendable (Root) -> (tag: String, payload: JSONObject)?

    /// An unknown case from the two halves: reading, given the tag and every
    /// other member of the object, and writing, which returns the tag and the
    /// members to write for a value that is the unknown case, and `nil` for
    /// any other.
    ///
    /// - Parameters:
    ///   - name: The case's name, for the warning.
    ///   - read: Makes the value for a tag that names no case. The payload is
    ///     the object without its discriminator, as the server sent it.
    ///   - write: The tag and payload of an unknown-case value. The payload
    ///     is written beside the discriminator; a member of it named like the
    ///     discriminator is ignored.
    public init(
        name: String = "unknown",
        read: @escaping @Sendable (_ tag: String, _ payload: JSONObject) -> Root,
        write: @escaping @Sendable (Root) -> (tag: String, payload: JSONObject)?
    ) {
        self.name = name
        self.read = read
        self.write = write
    }

    /// A plain unknown case that keeps nothing: any unknown tag is read as
    /// `value`, and `value` is written as `{"type": "<name>"}` (the case's own
    /// name, like an enumeration's unknown case, which writes its own raw
    /// value). What the server sent is lost.
    ///
    /// - Parameters:
    ///   - value: The case.
    ///   - name: Its name, which is also its tag when written.
    ///   - matches: Whether a value is this case.
    public static func plain(
        _ value: Root, name: String = "unknown", matches: @escaping @Sendable (Root) -> Bool
    ) -> UnknownTag<Root> {
        UnknownTag(
            name: name, read: { _, _ in value },
            write: { matches($0) ? (name, JSONObject()) : nil })
    }

    /// An unknown case that keeps the tag it did not understand, like
    /// `case unknown(String)` of an enumeration. It is written back with that
    /// tag and no other member: the payload was not kept.
    ///
    /// - Parameters:
    ///   - name: The case's name, for the warning.
    ///   - make: Builds the case from the tag.
    ///   - extract: The tag if the value is this case, otherwise `nil`.
    public static func keepingTag(
        name: String = "unknown",
        _ make: @escaping @Sendable (String) -> Root,
        extract: @escaping @Sendable (Root) -> String?
    ) -> UnknownTag<Root> {
        UnknownTag(
            name: name, read: { tag, _ in make(tag) },
            write: { value in extract(value).map { ($0, JSONObject()) } })
    }

    /// An unknown case that keeps the tag and everything else the server sent,
    /// so that it is written back as it was read: a client that relays a
    /// record it only partly understands does not lose the part it does not.
    ///
    /// - Parameters:
    ///   - name: The case's name, for the warning.
    ///   - make: Builds the case from the tag and the other members.
    ///   - extract: The tag and members if the value is this case, otherwise `nil`.
    public static func keepingPayload(
        name: String = "unknown",
        _ make: @escaping @Sendable (String, JSONObject) -> Root,
        extract: @escaping @Sendable (Root) -> (tag: String, payload: JSONObject)?
    ) -> UnknownTag<Root> {
        UnknownTag(name: name, read: make, write: extract)
    }
}
