/// A position in JSON source text.
///
/// Three numbers, because three audiences need three different ones: `offset`
/// is for code that slices the original bytes, `line` and `column` are for a
/// person looking at an editor. The column counts Unicode scalars, not bytes
/// and not grapheme clusters: an editor's caret moves by characters the user
/// can see, and a byte count would point into the middle of any accented
/// letter on the line, while a grapheme count would depend on the Unicode
/// version of whoever renders the message.
///
/// A line ends at `\n`, at `\r\n`, or at a lone `\r`, so a file with classic
/// Mac line endings still reports sensible lines. A leading byte order mark
/// counts toward `offset` but not toward `column`.
public struct SourceLocation: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Distance in UTF-8 bytes from the start of the input, starting at 0.
    public var offset: Int

    /// The line, starting at 1.
    public var line: Int

    /// The column in Unicode scalars from the start of the line, starting at 1.
    public var column: Int

    public init(offset: Int, line: Int, column: Int) {
        self.offset = offset
        self.line = line
        self.column = column
    }

    public static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        lhs.offset < rhs.offset
    }

    /// `line:column`, the form editors and compilers print.
    public var description: String { "\(line):\(column)" }
}

/// The text a value or a key occupies: `start` is the first byte, `end` is
/// the position just past the last, so the range is half-open like every
/// Swift range.
public struct SourceRange: Sendable, Hashable, CustomStringConvertible {
    public var start: SourceLocation
    public var end: SourceLocation

    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }

    /// The UTF-8 byte offsets this range covers.
    public var offsets: Range<Int> { start.offset..<max(start.offset, end.offset) }

    public var description: String { "\(start)-\(end)" }
}

/// Maps byte offsets to lines and columns.
///
/// Two ways to build one, because there are two situations. A document keeps
/// a table of line starts, so any number of queries cost a binary search
/// plus a walk along one line. A parse error needs exactly one answer, once,
/// so it scans the prefix instead of building a table nobody asked for; this
/// matters when a hostile input fails at its first bytes and is megabytes
/// long.
struct LineMap: Sendable {
    /// Offset of the first byte of each line; never empty.
    let lineStarts: [Int]

    init(bytes: [UInt8], textStart: Int) {
        var starts = [textStart]
        var index = textStart
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if byte == 0x0A {
                starts.append(index + 1)
            } else if byte == 0x0D, index + 1 >= count || bytes[index + 1] != 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
        lineStarts = starts
    }

    func location(ofOffset offset: Int, in bytes: [UInt8]) -> SourceLocation {
        let clamped = min(max(offset, 0), bytes.count)
        // Last line start at or before the offset.
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= clamped { low = middle } else { high = middle - 1 }
        }
        let lineStart = min(lineStarts[low], clamped)
        return SourceLocation(
            offset: clamped,
            line: low + 1,
            column: 1 + Self.scalarCount(in: bytes, from: lineStart, to: clamped)
        )
    }

    /// Locates one offset by scanning the bytes before it.
    static func locate(offset: Int, in bytes: [UInt8], textStart: Int) -> SourceLocation {
        let clamped = min(max(offset, 0), bytes.count)
        var line = 1
        var lineStart = min(textStart, clamped)
        var index = min(textStart, clamped)
        while index < clamped {
            let byte = bytes[index]
            if byte == 0x0A {
                line += 1
                lineStart = index + 1
            } else if byte == 0x0D, index + 1 >= bytes.count || bytes[index + 1] != 0x0A {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        return SourceLocation(
            offset: clamped,
            line: line,
            column: 1 + scalarCount(in: bytes, from: lineStart, to: clamped)
        )
    }

    /// Unicode scalars in `bytes[from..<to]`: every byte that is not a UTF-8
    /// continuation byte starts one.
    private static func scalarCount(in bytes: [UInt8], from: Int, to: Int) -> Int {
        var count = 0
        var index = from
        while index < to {
            if bytes[index] & 0xC0 != 0x80 { count += 1 }
            index += 1
        }
        return count
    }
}
