extension JSONPath {
    /// What an app knows of a document's shape that decides how a dotted
    /// address reads: where the keys are fixed, and where they are the
    /// person's.
    ///
    /// `web.routes.github.com` is the key `github.com` in `routes`, not a key
    /// `github` holding `com`, because `routes` is a table whose keys are
    /// hostnames. The dots in a path text cannot say that; the shape does.
    /// ``init(address:shape:)`` reads an address with it.
    ///
    ///     let shape: JSONPath.Shape = .fields([
    ///         "scroll": .fields(["speed": .value]),
    ///         "web": .fields(["routes": .freeKeys(.value)]),   // keys are hostnames
    ///     ])
    ///
    /// A schema's tree makes one (`SchemaNode.pathShape` in StoicSchema); an
    /// app whose validator is its own describes its tree directly.
    public indirect enum Shape: Sendable {
        /// A value with nothing described below it (a scalar, a `json` field):
        /// any further segments are plain keys, one per segment.
        case value
        /// An object whose keys are known. A segment that is none of them is
        /// an unknown key (the address is still read, as plain keys from
        /// there, so that whatever validates the document can report it).
        case fields([String: Shape])
        /// An object whose keys are free (a dictionary): a key may contain
        /// dots, each value is described by the shape.
        case freeKeys(Shape)
        /// An array. A segment of digits is an index; anything else is not an
        /// element, and is read as plain keys.
        case elements(Shape)
        /// A shape computed when it is reached, for one that contains
        /// itself.
        case deferred(@Sendable () -> Shape)
    }

    /// The path a dotted address names in a document of `shape`; `nil` for an
    /// address with an empty segment (`a..b`, `.a`, `a.`), which no key can
    /// be addressed by. The empty address is the root.
    ///
    /// - **Fixed keys split on every dot.**
    /// - **A free key takes as many segments as it needs**, the fewest that
    ///   leave a remainder the shape can read: `web.links.my.site.url`, where
    ///   `links` is free-keyed and its values are objects with a `url`, is the
    ///   key `my.site` and then `url`; `web.routes.github.com`, where the
    ///   values hold nothing, is the key `github.com`. Where more than one
    ///   split reads, the shortest key wins, so address a key that is a
    ///   prefix of another's dotted spelling with care. When nothing leaves a
    ///   readable remainder the key takes them all.
    /// - **An address the shape does not describe** (an unknown key, a
    ///   segment below a scalar) is read as plain keys from there on, and
    ///   still returns a path: it is for the validator to say the key is not
    ///   one, not the address parser.
    public init?(address: String, shape: Shape) {
        let segments = address.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if address.isEmpty {
            self.init()
            return
        }
        guard !segments.contains(where: \.isEmpty) else { return nil }
        var components: [Component] = []
        var shape = shape
        var index = 0
        read: while index < segments.count {
            switch shape.resolved {
            case .fields(let fields):
                let key = segments[index]
                components.append(.key(key))
                index += 1
                guard let next = fields[key] else { break read }
                shape = next
            case .freeKeys(let value):
                let remaining = segments[index...]
                let width = (1...remaining.count).first { width in
                    value.reads(Array(remaining.dropFirst(width)))
                } ?? remaining.count
                components.append(.key(remaining.prefix(width).joined(separator: ".")))
                index += width
                shape = value
            case .elements(let element):
                guard let position = Self.arrayIndex(segments[index]) else { break read }
                components.append(.index(position))
                index += 1
                shape = element
            case .value, .deferred:
                break read
            }
        }
        components += segments[index...].map(Component.key)
        self.init(components)
    }

    /// A segment of digits with no leading zero, small enough for an `Int`.
    fileprivate static func arrayIndex(_ segment: String) -> Int? {
        guard let first = segment.utf8.first, segment.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        if first == UInt8(ascii: "0"), segment.utf8.count > 1 { return nil }
        return Int(segment)
    }
}

extension JSONPath.Shape {
    /// The shape itself, with `deferred` ones computed.
    fileprivate var resolved: JSONPath.Shape {
        var shape = self
        while case .deferred(let make) = shape { shape = make() }
        return shape
    }

    /// Whether `segments` name something this shape describes.
    fileprivate func reads(_ segments: [String]) -> Bool {
        guard let head = segments.first else { return true }
        switch resolved {
        case .fields(let fields):
            guard let next = fields[head] else { return false }
            return next.reads(Array(segments.dropFirst()))
        case .freeKeys:
            // A free key can hold any dotted remainder, whole.
            return true
        case .elements(let element):
            guard JSONPath.arrayIndex(head) != nil else { return false }
            return element.reads(Array(segments.dropFirst()))
        case .value, .deferred:
            return false
        }
    }
}
