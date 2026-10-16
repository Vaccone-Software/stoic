/// A parsed JSON value together with where every part of it came from.
///
/// Validation errors are only as useful as their pointing. A schema layer
/// that finds `$.network.hosts[3]` out of range wants to underline the
/// `99999` in the file, and a document answers that: ``range(of:)`` for the
/// text of any value, ``keyRange(of:)`` for the text of the key that names
/// it. Ranges are recorded while parsing, so asking costs a path walk and a
/// line lookup, not a re-parse.
///
/// Where an object repeated a key and the policy kept one occurrence, the
/// ranges are those of the occurrence whose value was kept.
public struct JSONDocument: Sendable {
    /// The parsed value.
    public let value: JSONValue

    /// The exact bytes that were parsed, including any byte order mark.
    public let source: [UInt8]

    private let lineMap: LineMap
    private let nodes: [RangeNode]
    private let childTable: [UInt32]
    private let rootNode: UInt32

    init(core: ParserCore) {
        value = core.root
        source = core.bytes
        lineMap = LineMap(bytes: core.bytes, textStart: core.textStart)
        nodes = core.nodes
        childTable = core.childTable
        rootNode = core.rootNode
    }

    /// Parses `bytes`. See ``JSONParseOptions`` for dialects and limits.
    public init(
        parsing bytes: some Collection<UInt8>,
        options: JSONParseOptions = .strict
    ) throws(JSONParseError) {
        self = try JSONParser(options: options).parse(bytes)
    }

    public init(parsing text: String, options: JSONParseOptions = .strict) throws(JSONParseError) {
        try self.init(parsing: text.utf8, options: options)
    }

    // MARK: Locations

    /// The line and column of a byte offset into ``source``. An offset
    /// outside the source is clamped to its ends.
    public func location(ofOffset offset: Int) -> SourceLocation {
        lineMap.location(ofOffset: offset, in: source)
    }

    /// The text of `range`, or `nil` if it does not lie within the source on
    /// scalar boundaries.
    public func text(in range: SourceRange) -> String? {
        let offsets = range.offsets
        guard offsets.lowerBound >= 0, offsets.upperBound <= source.count else { return nil }
        return String(validating: source[offsets], as: UTF8.self)
    }

    // MARK: Ranges

    /// The text the whole document's value occupies.
    public var range: SourceRange {
        range(ofNode: rootNode)
    }

    /// The text the value at `path` occupies, quotes and brackets included,
    /// or `nil` if the path does not lead to a value.
    public func range(of path: JSONPath) -> SourceRange? {
        node(at: path).map(range(ofNode:))
    }

    /// The text of the key that names the value at `path`, quotes included.
    /// `nil` for the root, for array elements, and for paths that lead
    /// nowhere.
    public func keyRange(of path: JSONPath) -> SourceRange? {
        guard let id = node(at: path) else { return nil }
        let node = nodes[Int(id)]
        guard node.keyStart != RangeNode.noKey else { return nil }
        return SourceRange(
            start: location(ofOffset: Int(node.keyStart)),
            end: location(ofOffset: Int(node.keyEnd))
        )
    }

    private func range(ofNode id: UInt32) -> SourceRange {
        let node = nodes[Int(id)]
        return SourceRange(
            start: location(ofOffset: Int(node.start)),
            end: location(ofOffset: Int(node.end))
        )
    }

    // MARK: Offsets

    /// The bytes the value at `path` occupies: what ``range(of:)`` says,
    /// without the lines and columns.
    ///
    /// A column costs a walk along its line, and a minified document is one
    /// line, so asking ``range(of:)`` for each of a thousand problems in a
    /// megabyte costs a thousand megabyte walks. Code that reports many
    /// positions collects offsets as it goes and turns them into ranges once,
    /// with ``ranges(ofOffsets:)``.
    public func offsets(of path: JSONPath) -> Range<Int>? {
        guard let id = node(at: path) else { return nil }
        let node = nodes[Int(id)]
        return Int(node.start)..<Int(node.end)
    }

    /// The bytes of the key that names the value at `path`: what
    /// ``keyRange(of:)`` says, without the lines and columns.
    public func keyOffsets(of path: JSONPath) -> Range<Int>? {
        guard let id = node(at: path) else { return nil }
        let node = nodes[Int(id)]
        guard node.keyStart != RangeNode.noKey else { return nil }
        return Int(node.keyStart)..<Int(node.keyEnd)
    }

    /// The source range of each offset range, in the same order, found in
    /// one pass over the text however many there are: O(bytes + n log n)
    /// where asking one at a time is O(n × line length).
    public func ranges(ofOffsets offsets: [Range<Int>]) -> [SourceRange] {
        let ends = offsets.flatMap { [$0.lowerBound, $0.upperBound] }
        let locations = lineMap.locations(ofOffsets: ends, in: source)
        return offsets.indices.map { SourceRange(start: locations[2 * $0], end: locations[2 * $0 + 1]) }
    }

    /// Walks the value and the range tree together: the value says which
    /// child a key or index means, the tree says where that child was.
    private func node(at path: JSONPath) -> UInt32? {
        var id = rootNode
        var current = value
        for component in path {
            let node = nodes[Int(id)]
            switch (component, current) {
            case (.key(let key), .object(let object)):
                guard let position = object.index(forKey: key) else { return nil }
                id = childTable[Int(node.childStart) + position]
                current = object[position].value
            case (.index(let index), .array(let array)):
                guard array.indices.contains(index) else { return nil }
                id = childTable[Int(node.childStart) + index]
                current = array[index]
            default:
                return nil
            }
        }
        return id
    }
}
