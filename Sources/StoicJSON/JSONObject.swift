/// A JSON object: members in the order they were written, looked up by key
/// in constant time on average.
///
/// Order is kept because people read files in order and diff them, and
/// because the pretty encoder promises to preserve it. It is not part of the
/// object's identity: `==` and `hash(into:)` ignore it, since `{"a":1,"b":2}`
/// and `{"b":2,"a":1}` are the same JSON object.
///
/// Keys are unique, compared by Unicode scalars rather than by Swift's
/// canonical equivalence (`"é"` and `"e\u{301}"` are two keys). The parser
/// resolves duplicates by policy before an object exists; the mutating API
/// here resolves them the way a script object does: assigning an existing
/// key replaces its value and keeps its place.
///
/// An object is a `RandomAccessCollection` of ``Member``s in source order.
public struct JSONObject: Sendable, Hashable, RandomAccessCollection {
    /// One key and value of an object.
    public struct Member: Sendable, Hashable {
        public var key: String
        public var value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }

        public static func == (lhs: Member, rhs: Member) -> Bool {
            lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value == rhs.value
        }

        public func hash(into hasher: inout Hasher) {
            ExactString(key).hash(into: &hasher)
            hasher.combine(value)
        }
    }

    private var members: [Member]
    private var positions: [ExactString: Int]

    public init() {
        members = []
        positions = [:]
    }

    /// Builds an object from members. A later member whose key repeats an
    /// earlier one replaces that member's value and keeps its position.
    public init(_ members: some Sequence<Member>) {
        self.init()
        for member in members { self[member.key] = member.value }
    }

    // MARK: Collection

    public var startIndex: Int { 0 }
    public var endIndex: Int { members.count }

    public subscript(position: Int) -> Member { members[position] }

    // MARK: Lookup

    /// The value for `key`, found in constant time on average. Assigning
    /// replaces the value in place or appends a new member; assigning `nil`
    /// removes the member, which costs time linear in the object's size
    /// because later members shift down.
    public subscript(key: String) -> JSONValue? {
        get {
            guard let position = positions[ExactString(key)] else { return nil }
            return members[position].value
        }
        set {
            if let newValue {
                if let position = positions[ExactString(key)] {
                    members[position].value = newValue
                } else {
                    positions[ExactString(key)] = members.count
                    members.append(Member(key: key, value: newValue))
                }
            } else if let position = positions[ExactString(key)] {
                members.remove(at: position)
                positions[ExactString(key)] = nil
                if position < members.count {
                    for later in position..<members.count {
                        positions[ExactString(members[later].key)] = later
                    }
                }
            }
        }
    }

    /// The position of `key` among the members, or `nil`.
    public func index(forKey key: String) -> Int? {
        positions[ExactString(key)]
    }

    public func contains(key: String) -> Bool {
        positions[ExactString(key)] != nil
    }

    /// The keys, in source order.
    public var keys: [String] { members.map(\.key) }

    // MARK: Parser support

    /// Appends a member whose key the caller has checked is absent.
    mutating func appendUnchecked(_ member: Member) {
        positions[ExactString(member.key)] = members.count
        members.append(member)
    }

    /// Replaces the value of the member at `position`.
    mutating func replaceValue(at position: Int, with value: JSONValue) {
        members[position].value = value
    }

    // MARK: Equality

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        guard lhs.members.count == rhs.members.count else { return false }
        for member in lhs.members {
            guard let other = rhs[member.key], other == member.value else { return false }
        }
        return true
    }

    /// Combines member hashes with a commutative sum, so the order the
    /// members were written in cannot change the hash.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(members.count)
        var sum = 0
        for member in members {
            var memberHasher = Hasher()
            member.hash(into: &memberHasher)
            sum = sum &+ memberHasher.finalize()
        }
        hasher.combine(sum)
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements.map { Member(key: $0.0, value: $0.1) })
    }
}
