/// Reads JSON text under a set of options.
///
/// The parser is a hand-written state machine with an explicit stack, not a
/// recursive descent: the depth of the input decides how much memory it
/// uses, never how much of the call stack, so a hostile `[[[[...` of any
/// length fails with `depth_limit` after reading `maxDepth + 1` brackets
/// instead of crashing the process.
public struct JSONParser: Sendable {
    public var options: JSONParseOptions

    public init(options: JSONParseOptions = .strict) {
        self.options = options
    }

    /// Parses `bytes` as one JSON value, keeping the source range of every
    /// value and every object key.
    public func parse(_ bytes: some Collection<UInt8>) throws(JSONParseError) -> JSONDocument {
        var core = try makeCore(bytes, trackRanges: true)
        try core.run()
        return JSONDocument(core: core)
    }

    /// Parses `text` as one JSON value.
    public func parse(_ text: String) throws(JSONParseError) -> JSONDocument {
        try parse(text.utf8)
    }

    /// Parses `bytes` and returns only the value, skipping the bookkeeping
    /// that source ranges need.
    public func parseValue(_ bytes: some Collection<UInt8>) throws(JSONParseError) -> JSONValue {
        var core = try makeCore(bytes, trackRanges: false)
        try core.run()
        return core.root
    }

    public func parseValue(_ text: String) throws(JSONParseError) -> JSONValue {
        try parseValue(text.utf8)
    }

    private func makeCore(_ input: some Collection<UInt8>, trackRanges: Bool) throws(JSONParseError) -> ParserCore {
        // Source ranges are 32-bit; see `JSONParseOptions.maxBytes`.
        let limit = min(max(options.maxBytes, 0), Int(UInt32.max) - 1)
        if input.count > limit {
            // Copy only what is needed to say where the limit was crossed.
            let prefix = Array(input.prefix(limit))
            throw JSONParseError(
                code: .sizeLimit,
                location: LineMap.locate(offset: limit, in: prefix, textStart: 0),
                path: .root,
                message: "the input is \(input.count) bytes, more than the limit of \(limit)"
            )
        }
        return ParserCore(bytes: Array(input), options: options, trackRanges: trackRanges)
    }
}

extension JSONValue {
    /// Parses `bytes` as JSON. See ``JSONParseOptions`` for dialects and limits.
    public init(
        parsing bytes: some Collection<UInt8>,
        options: JSONParseOptions = .strict
    ) throws(JSONParseError) {
        self = try JSONParser(options: options).parseValue(bytes)
    }

    public init(parsing text: String, options: JSONParseOptions = .strict) throws(JSONParseError) {
        try self.init(parsing: text.utf8, options: options)
    }
}

// MARK: - The state machine

/// Per-node source ranges, 32-bit to keep a million-element array's
/// bookkeeping to tens of megabytes.
struct RangeNode: Sendable {
    static let noKey = UInt32.max

    var start: UInt32
    var end: UInt32
    var keyStart: UInt32
    var keyEnd: UInt32
    /// Where this node's children begin in the document's child table.
    var childStart: UInt32
    var childCount: UInt32
}

struct ParserCore {
    enum Kind { case array, object }

    /// An open array or object.
    struct Frame {
        var kind: Kind
        var openOffset: Int
        var elements: [JSONValue] = []
        var object = JSONObject()
        /// Where each member's key began, parallel to the object's members.
        var keyOffsets: [Int] = []
        /// Range nodes of the children, parallel to the elements or members.
        var childIDs: [UInt32] = []

        var pendingKey: String?
        var pendingKeyStart = 0
        var pendingKeyEnd = 0
        /// The existing member the pending key repeats, if any.
        var pendingDuplicateSlot: Int?

        var count: Int { kind == .array ? elements.count : object.count }
    }

    private enum State {
        /// A value is expected next.
        case value
        /// An object key is expected next.
        case key
        /// A value just finished inside a container.
        case afterValue
        case done
    }

    let bytes: [UInt8]
    private let count: Int
    private let jsonc: Bool
    private let allowBOM: Bool
    private let duplicateKeys: JSONParseOptions.DuplicateKeys
    private let maxDepth: Int
    private let maxStringBytes: Int
    private let maxContainerCount: Int
    private let trackRanges: Bool

    private(set) var textStart = 0
    private var position = 0
    private var frames: [Frame] = []
    private var scratch: [UInt8] = []

    private(set) var root: JSONValue = .null
    private(set) var rootNode: UInt32 = 0
    private(set) var nodes: [RangeNode] = []
    private(set) var childTable: [UInt32] = []

    init(bytes: [UInt8], options: JSONParseOptions, trackRanges: Bool) {
        self.bytes = bytes
        count = bytes.count
        jsonc = options.dialect == .jsonc
        allowBOM = options.allowBOM
        duplicateKeys = options.duplicateKeys
        maxDepth = options.maxDepth
        maxStringBytes = options.maxStringBytes
        maxContainerCount = options.maxContainerCount
        self.trackRanges = trackRanges
    }

    // MARK: Driver

    mutating func run() throws(JSONParseError) {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard allowBOM else {
                throw fail(
                    .byteOrderMark, at: 0,
                    "the input starts with a byte order mark (U+FEFF); JSON text must not, unless the parser is told to allow it"
                )
            }
            position = 3
            textStart = 3
        }
        try skipTrivia()
        guard position < count else {
            throw fail(.emptyInput, at: position, "the input contains no JSON value")
        }

        var state = State.value
        while state != .done {
            switch state {
            case .value: state = try readValue()
            case .key: state = try readKey()
            case .afterValue: state = try readAfterValue()
            case .done: break
            }
        }

        try skipTrivia()
        if position < count {
            throw fail(
                .trailingContent, at: position,
                "unexpected \(describe(at: position)) after the end of the JSON value"
            )
        }
    }

    // MARK: Values

    private mutating func readValue() throws(JSONParseError) -> State {
        try skipTrivia()
        guard position < count else {
            throw fail(.unexpectedEnd, at: count, "the input ended where a value was expected")
        }
        if let top = frames.last, top.kind == .array, top.count >= maxContainerCount {
            throw fail(
                .containerLimit, at: position,
                "the array has more than \(maxContainerCount) elements, the limit"
            )
        }

        let start = position
        let byte = bytes[position]
        switch byte {
        case UInt8(ascii: "{"):
            try open(.object)
            position += 1
            try skipTrivia()
            if position < count, bytes[position] == UInt8(ascii: "}") { return close() }
            return .key
        case UInt8(ascii: "["):
            try open(.array)
            position += 1
            try skipTrivia()
            if position < count, bytes[position] == UInt8(ascii: "]") { return close() }
            return .value
        case UInt8(ascii: "\""):
            let string = try readString()
            return completeScalar(.string(string), start: start)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            let number = try readNumber()
            return completeScalar(.number(number), start: start)
        case UInt8(ascii: "t"):
            try readLiteral("true")
            return completeScalar(.bool(true), start: start)
        case UInt8(ascii: "f"):
            try readLiteral("false")
            return completeScalar(.bool(false), start: start)
        case UInt8(ascii: "n"):
            try readLiteral("null")
            return completeScalar(.null, start: start)
        case UInt8(ascii: "+"), UInt8(ascii: "."):
            throw fail(
                    .invalidNumber, at: position,
                    "a number cannot start with '\(Character(Unicode.Scalar(byte)))'; JSON numbers are an optional '-', digits, an optional fraction and an optional exponent"
                )
        case UInt8(ascii: "N") where matches("NaN", at: position),
            UInt8(ascii: "I") where matches("Infinity", at: position):
            throw fail(.invalidNumber, at: position, "NaN and Infinity are not valid JSON; JSON has no way to write them")
        default:
            throw unexpected(at: position, expected: "a value")
        }
    }

    private mutating func completeScalar(_ value: JSONValue, start: Int) -> State {
        let node = makeNode(start: start, end: position, children: [])
        attach(value, node: node)
        return frames.isEmpty ? .done : .afterValue
    }

    private mutating func open(_ kind: Kind) throws(JSONParseError) {
        guard frames.count < maxDepth else {
            throw fail(
                .depthLimit, at: position,
                "nesting is deeper than \(maxDepth) levels, the limit"
            )
        }
        frames.append(Frame(kind: kind, openOffset: position))
    }

    /// Closes the container whose closing bracket is at `position`.
    private mutating func close() -> State {
        let frame = frames.removeLast()
        position += 1
        let value: JSONValue = frame.kind == .array ? .array(frame.elements) : .object(frame.object)
        let node = makeNode(start: frame.openOffset, end: position, children: frame.childIDs)
        attach(value, node: node)
        return frames.isEmpty ? .done : .afterValue
    }

    private mutating func attach(_ value: JSONValue, node: UInt32) {
        guard let top = frames.indices.last else {
            root = value
            rootNode = node
            return
        }
        switch frames[top].kind {
        case .array:
            frames[top].elements.append(value)
            if trackRanges { frames[top].childIDs.append(node) }
        case .object:
            guard let key = frames[top].pendingKey else {
                preconditionFailure("an object value was completed without a key")
            }
            if let slot = frames[top].pendingDuplicateSlot {
                // `.reject` never gets here: it failed when the key was read.
                if duplicateKeys == .lastWins {
                    frames[top].object.replaceValue(at: slot, with: value)
                    if trackRanges { frames[top].childIDs[slot] = node }
                }
            } else {
                frames[top].keyOffsets.append(frames[top].pendingKeyStart)
                frames[top].object.appendUnchecked(JSONObject.Member(key: key, value: value))
                if trackRanges { frames[top].childIDs.append(node) }
            }
            frames[top].pendingKey = nil
            frames[top].pendingDuplicateSlot = nil
        }
    }

    private mutating func makeNode(start: Int, end: Int, children: [UInt32]) -> UInt32 {
        guard trackRanges else { return 0 }
        var keyStart = RangeNode.noKey
        var keyEnd = RangeNode.noKey
        if let top = frames.last, top.kind == .object {
            keyStart = UInt32(top.pendingKeyStart)
            keyEnd = UInt32(top.pendingKeyEnd)
        }
        let childStart = UInt32(childTable.count)
        childTable.append(contentsOf: children)
        nodes.append(
            RangeNode(
                start: UInt32(start), end: UInt32(end),
                keyStart: keyStart, keyEnd: keyEnd,
                childStart: childStart, childCount: UInt32(children.count)
            )
        )
        return UInt32(nodes.count - 1)
    }

    // MARK: Structure

    private mutating func readKey() throws(JSONParseError) -> State {
        try skipTrivia()
        guard position < count else {
            throw fail(.unexpectedEnd, at: count, "the input ended where an object key was expected")
        }
        let top = frames.count - 1
        if frames[top].count >= maxContainerCount {
            throw fail(
                .containerLimit, at: position,
                "the object has more than \(maxContainerCount) members, the limit"
            )
        }
        guard bytes[position] == UInt8(ascii: "\"") else {
            throw unexpected(at: position, expected: "a string as an object key")
        }

        let keyStart = position
        let key = try readString()
        frames[top].pendingKey = key
        frames[top].pendingKeyStart = keyStart
        frames[top].pendingKeyEnd = position

        if let slot = frames[top].object.index(forKey: key) {
            if duplicateKeys == .reject {
                let first = frames[top].keyOffsets[slot]
                let firstLocation = LineMap.locate(offset: first, in: bytes, textStart: textStart)
                throw fail(
                    .duplicateKey, at: keyStart,
                    "duplicate key \(quoted(key)); first defined at line \(firstLocation.line), column \(firstLocation.column)",
                    related: first
                )
            }
            frames[top].pendingDuplicateSlot = slot
        }

        try skipTrivia()
        guard position < count else {
            throw fail(.unexpectedEnd, at: count, "the input ended where ':' was expected")
        }
        guard bytes[position] == UInt8(ascii: ":") else {
            throw unexpected(at: position, expected: "':' after an object key")
        }
        position += 1
        return .value
    }

    private mutating func readAfterValue() throws(JSONParseError) -> State {
        try skipTrivia()
        let kind = frames[frames.count - 1].kind
        let closer = kind == .array ? UInt8(ascii: "]") : UInt8(ascii: "}")
        let expectation = kind == .array ? "',' or ']'" : "',' or '}'"
        guard position < count else {
            throw fail(.unexpectedEnd, at: count, "the input ended where \(expectation) was expected")
        }

        let byte = bytes[position]
        if byte == closer { return close() }
        guard byte == UInt8(ascii: ",") else {
            throw unexpected(at: position, expected: expectation)
        }

        let comma = position
        position += 1
        try skipTrivia()
        guard position < count else {
            throw fail(
                .unexpectedEnd, at: count,
                "the input ended where \(kind == .array ? "a value" : "an object key") was expected"
            )
        }
        if bytes[position] == closer {
            guard jsonc else {
                throw fail(
                    .trailingComma, at: comma,
                    "a trailing comma is not allowed in strict JSON; remove it, or parse with the .jsonc dialect"
                )
            }
            return close()
        }
        return kind == .array ? .value : .key
    }

    // MARK: Trivia

    /// Skips whitespace and, in `.jsonc`, comments. Comments are checked for
    /// valid UTF-8 like any other text: a parser that skipped bytes it never
    /// looked at would disagree with one that did.
    private mutating func skipTrivia() throws(JSONParseError) {
        while position < count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D:
                position += 1
            case UInt8(ascii: "/"):
                guard jsonc else {
                    throw fail(
                        .commentNotAllowed, at: position,
                        "comments are not allowed in strict JSON; parse with the .jsonc dialect to allow them"
                    )
                }
                guard position + 1 < count, bytes[position + 1] == UInt8(ascii: "/") || bytes[position + 1] == UInt8(ascii: "*")
                else {
                    throw unexpected(at: position, expected: "'//' or '/*' to start a comment")
                }
                if bytes[position + 1] == UInt8(ascii: "/") {
                    try skipLineComment()
                } else {
                    try skipBlockComment()
                }
            default:
                return
            }
        }
    }

    private mutating func skipLineComment() throws(JSONParseError) {
        position += 2
        while position < count {
            let byte = bytes[position]
            if byte == 0x0A || byte == 0x0D { return }
            if byte >= 0x80 {
                position += try sequenceLength(at: position)
            } else {
                position += 1
            }
        }
    }

    private mutating func skipBlockComment() throws(JSONParseError) {
        let start = position
        position += 2
        while position < count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "*"), position + 1 < count, bytes[position + 1] == UInt8(ascii: "/") {
                position += 2
                return
            }
            if byte >= 0x80 {
                position += try sequenceLength(at: position)
            } else {
                position += 1
            }
        }
        throw fail(.unterminatedComment, at: start, "this comment is never closed; expected '*/'")
    }

    // MARK: Literals and numbers

    private func matches(_ literal: String, at offset: Int) -> Bool {
        var index = offset
        for expected in literal.utf8 {
            guard index < count, bytes[index] == expected else { return false }
            index += 1
        }
        return true
    }

    private mutating func readLiteral(_ literal: String) throws(JSONParseError) {
        var index = position
        for expected in literal.utf8 {
            guard index < count else {
                throw fail(.unexpectedEnd, at: count, "the input ended inside '\(literal)'")
            }
            guard bytes[index] == expected else {
                throw unexpected(at: index, expected: "'\(literal)'")
            }
            index += 1
        }
        if index < count {
            let byte = bytes[index]
            let isWordCharacter =
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == UInt8(ascii: "_")
            if isWordCharacter {
                throw unexpected(at: index, expected: "the end of '\(literal)'")
            }
        }
        position = index
    }

    private mutating func readNumber() throws(JSONParseError) -> JSONNumber {
        let start = position
        if bytes[start] == UInt8(ascii: "-"), matches("-Infinity", at: start) {
            throw fail(.invalidNumber, at: start, "NaN and Infinity are not valid JSON; JSON has no way to write them")
        }
        let end: Int
        switch scanJSONNumber(bytes, from: start) {
        case .success(let scanned):
            end = scanned
        case .failure(let failure):
            if failure.offset >= count {
                throw fail(.invalidNumber, at: count, "the input ended inside a number: \(failure.reason)")
            }
            throw fail(
                .invalidNumber, at: failure.offset,
                "invalid number: \(failure.reason), found \(describe(at: failure.offset))"
            )
        }

        let lexeme = String(decoding: bytes[start..<end], as: UTF8.self)
        let number = JSONNumber(validatedLexeme: lexeme)
        // Converting is the expensive part, and a short lexeme without an
        // exponent cannot leave the range of a Double (fewer than 309 digits
        // never overflows, and no nonzero decimal of under 300 characters
        // underflows to zero).
        var hasExponent = false
        for byte in bytes[start..<end] where byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
            hasExponent = true
            break
        }
        if hasExponent || end - start > 300, number.double == nil {
            let shown = lexeme.count > 40 ? String(lexeme.prefix(40)) + "..." : lexeme
            throw fail(
                .numberOutOfRange, at: start,
                "the number \(shown) is outside the range of a 64-bit floating-point number (about 1e-324 to 1.8e308)"
            )
        }
        position = end
        return number
    }

    // MARK: Strings

    /// Reads the string whose opening quote is at `position`.
    private mutating func readString() throws(JSONParseError) -> String {
        let start = position
        position += 1
        scratch.removeAll(keepingCapacity: true)

        while true {
            // A run of plain ASCII needs no per-byte decisions.
            let runStart = position
            while position < count {
                let byte = bytes[position]
                if byte < 0x20 || byte >= 0x80 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") { break }
                position += 1
            }
            if position > runStart { scratch.append(contentsOf: bytes[runStart..<position]) }
            if scratch.count > maxStringBytes {
                throw fail(
                    .stringLimit, at: start,
                    "the string is longer than \(maxStringBytes) bytes (UTF-8), the limit"
                )
            }

            guard position < count else {
                throw fail(.unterminatedString, at: start, "this string is never closed; expected '\"'")
            }
            let byte = bytes[position]
            switch byte {
            case UInt8(ascii: "\""):
                position += 1
                return String(decoding: scratch, as: UTF8.self)
            case UInt8(ascii: "\\"):
                try readEscape(stringStart: start)
            case 0..<0x20:
                throw fail(
                    .controlCharacter, at: position,
                    "unescaped control character \(describe(at: position)) in a string; write it as an escape such as \\u\(hex4(UInt32(byte)))"
                )
            default:
                let length = try sequenceLength(at: position)
                scratch.append(contentsOf: bytes[position..<position + length])
                position += length
            }
        }
    }

    /// Reads one escape sequence starting at the backslash at `position`.
    private mutating func readEscape(stringStart: Int) throws(JSONParseError) {
        let escapeStart = position
        guard position + 1 < count else {
            throw fail(.unterminatedString, at: stringStart, "this string is never closed; expected '\"'")
        }
        let code = bytes[position + 1]
        switch code {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
            scratch.append(code)
            position += 2
        case UInt8(ascii: "b"):
            scratch.append(0x08)
            position += 2
        case UInt8(ascii: "f"):
            scratch.append(0x0C)
            position += 2
        case UInt8(ascii: "n"):
            scratch.append(0x0A)
            position += 2
        case UInt8(ascii: "r"):
            scratch.append(0x0D)
            position += 2
        case UInt8(ascii: "t"):
            scratch.append(0x09)
            position += 2
        case UInt8(ascii: "u"):
            let unit = try readHex4(at: position + 2, stringStart: stringStart)
            position += 6
            let scalarValue: UInt32
            switch unit {
            case 0xD800...0xDBFF:
                guard position + 1 < count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u")
                else {
                    throw fail(
                        .loneSurrogate, at: escapeStart,
                        "the high surrogate \\u\(hex4(unit)) must be followed by a \\u escape for a low surrogate (\\uDC00 to \\uDFFF)"
                    )
                }
                let low = try readHex4(at: position + 2, stringStart: stringStart)
                guard (0xDC00...0xDFFF).contains(low) else {
                    throw fail(
                        .loneSurrogate, at: escapeStart,
                        "the high surrogate \\u\(hex4(unit)) is followed by \\u\(hex4(low)), which is not a low surrogate (\\uDC00 to \\uDFFF)"
                    )
                }
                position += 6
                scalarValue = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
            case 0xDC00...0xDFFF:
                throw fail(
                    .loneSurrogate, at: escapeStart,
                    "the low surrogate \\u\(hex4(unit)) is not preceded by a high surrogate (\\uD800 to \\uDBFF)"
                )
            default:
                scalarValue = unit
            }
            // Surrogates were excluded above, so this cannot fail.
            if let scalar = Unicode.Scalar(scalarValue) {
                UTF8.encode(scalar) { scratch.append($0) }
            }
        default:
            let shown = code < 0x80 ? "'\\\(Character(Unicode.Scalar(code)))'" : "a backslash followed by a non-ASCII character"
            throw fail(
                .invalidEscape, at: escapeStart,
                "\(shown) is not a valid escape; the escapes are \\\" \\\\ \\/ \\b \\f \\n \\r \\t and \\uXXXX"
            )
        }
    }

    private func readHex4(at offset: Int, stringStart: Int) throws(JSONParseError) -> UInt32 {
        var value: UInt32 = 0
        for index in offset..<offset + 4 {
            guard index < count else {
                throw fail(.unterminatedString, at: stringStart, "this string is never closed; expected '\"'")
            }
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte) - 0x30
            case 0x41...0x46: digit = UInt32(byte) - 0x41 + 10
            case 0x61...0x66: digit = UInt32(byte) - 0x61 + 10
            default:
                throw fail(
                    .invalidUnicode, at: index,
                    "a \\u escape needs four hexadecimal digits, found \(describe(at: index))"
                )
            }
            value = value << 4 | digit
        }
        return value
    }

    // MARK: UTF-8

    /// The length of the well-formed UTF-8 sequence starting at `offset`
    /// (the byte there is 0x80 or above), per Unicode Table 3-7. Rejects
    /// overlong forms, encoded surrogates, anything above U+10FFFF, truncated
    /// sequences and continuation bytes with no lead.
    private func sequenceLength(at offset: Int) throws(JSONParseError) -> Int {
        let lead = bytes[offset]
        let length: Int
        var low: UInt8 = 0x80
        var high: UInt8 = 0xBF
        switch lead {
        case 0xC2...0xDF: length = 2
        case 0xE0: length = 3; low = 0xA0
        case 0xE1...0xEC, 0xEE...0xEF: length = 3
        case 0xED: length = 3; high = 0x9F
        case 0xF0: length = 4; low = 0x90
        case 0xF1...0xF3: length = 4
        case 0xF4: length = 4; high = 0x8F
        default:
            throw invalidUTF8(at: offset, "0x\(hex2(lead)) cannot start a UTF-8 sequence")
        }
        guard offset + length <= count else {
            throw invalidUTF8(at: offset, "the UTF-8 sequence starting with 0x\(hex2(lead)) is cut off by the end of the input")
        }
        for index in 1..<length {
            let byte = bytes[offset + index]
            let lower = index == 1 ? low : 0x80
            let upper = index == 1 ? high : 0xBF
            guard byte >= lower, byte <= upper else {
                throw invalidUTF8(
                    at: offset,
                    "the byte 0x\(hex2(byte)) cannot follow 0x\(hex2(lead)) in well-formed UTF-8 (overlong, surrogate or out-of-range encoding, or a bad continuation byte)"
                )
            }
        }
        return length
    }

    private func invalidUTF8(at offset: Int, _ detail: String) -> JSONParseError {
        fail(.invalidUTF8, at: offset, "invalid UTF-8: \(detail)")
    }

    // MARK: Diagnostics

    private func fail(
        _ code: JSONParseError.Code,
        at offset: Int,
        _ message: String,
        related: Int? = nil
    ) -> JSONParseError {
        JSONParseError(
            code: code,
            location: LineMap.locate(offset: offset, in: bytes, textStart: textStart),
            path: currentPath(),
            message: message,
            related: related.map { LineMap.locate(offset: $0, in: bytes, textStart: textStart) }
        )
    }

    /// An "unexpected character" error, or an invalid-UTF-8 error if the
    /// bytes there are not text at all.
    private func unexpected(at offset: Int, expected: String) -> JSONParseError {
        if bytes[offset] >= 0x80 {
            do throws(JSONParseError) {
                _ = try sequenceLength(at: offset)
            } catch {
                return error
            }
        }
        return fail(.unexpectedCharacter, at: offset, "unexpected \(describe(at: offset)); expected \(expected)")
    }

    private func currentPath() -> JSONPath {
        var components: [JSONPath.Component] = []
        components.reserveCapacity(frames.count)
        for frame in frames {
            switch frame.kind {
            case .array:
                components.append(.index(frame.elements.count))
            case .object:
                if let key = frame.pendingKey { components.append(.key(key)) }
            }
        }
        return JSONPath(components)
    }

    /// The character at `offset` for a message: `'x' (U+0078)`, or just the
    /// code point for control characters, which print as nothing useful.
    private func describe(at offset: Int) -> String {
        let lead = bytes[offset]
        var length = 1
        if lead >= 0xC2 {
            length = lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
        }
        let end = min(offset + length, count)
        let text = String(decoding: bytes[offset..<end], as: UTF8.self)
        guard let scalar = text.unicodeScalars.first, scalar != Unicode.Scalar(0xFFFD) || lead == 0xEF else {
            return "byte 0x\(hex2(lead))"
        }
        let code = "U+" + hex4(scalar.value)
        if scalar.value < 0x20 || scalar.value == 0x7F || scalar.properties.isWhitespace {
            return "character \(code)"
        }
        return "'\(Character(scalar))' (\(code))"
    }

    private func quoted(_ key: String) -> String {
        var out: [UInt8] = []
        JSONWriter.appendQuoted(key, to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    private func hex2(_ value: UInt8) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return digits.count < 2 ? "0" + digits : digits
    }

    private func hex4(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}
