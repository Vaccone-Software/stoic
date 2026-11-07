/// Reads the digits and signs of a number lexeme that already matches the
/// JSON grammar (`scanJSONNumber` has said so), one at a time, and says which
/// part of the number each is in.
///
/// Two readers need exactly this and differ in what they do with it:
/// `NumberParts` saturates an exponent past what any `Double` holds, and
/// refuses nothing; `ExactDecimal` declines a number whose exponent has more
/// than six digits. So the scanner decides nothing about the exponent. It
/// hands over every digit with its section, and each caller applies its own
/// policy to the ones in the exponent.
///
/// It holds the bytes' iterator and the section and nothing else, so reading
/// a lexeme allocates nothing. A lexeme that does not match the grammar has
/// no meaning here: its bytes are read as the digits and signs they resemble
/// (the arithmetic wraps rather than traps, as `NumberParts` always has), and
/// the result is a wrong number, not a diagnosis.
package struct NumberLexemeScanner: Sequence, IteratorProtocol {
    /// The part of the number a byte is in: `12` and `.34` and `e+5` in
    /// `12.34e+5`.
    package enum Section: Sendable {
        case integer
        case fraction
        case exponent
    }

    package enum Element: Sendable {
        /// A `-`: the number's own, in `.integer`, or its exponent's, in
        /// `.exponent`. (A `+` is not reported: it is the default.)
        case minus(in: Section)
        /// A digit, 0 through 9.
        case digit(UInt8, in: Section)
    }

    private var bytes: String.UTF8View.Iterator
    private var section = Section.integer

    package init(_ lexeme: String) {
        bytes = lexeme.utf8.makeIterator()
    }

    package mutating func next() -> Element? {
        while let byte = bytes.next() {
            switch byte {
            case UInt8(ascii: "-"):
                return .minus(in: section)
            case UInt8(ascii: "+"):
                continue
            case UInt8(ascii: "."):
                section = .fraction
            case UInt8(ascii: "e"), UInt8(ascii: "E"):
                section = .exponent
            default:
                return .digit(byte &- 0x30, in: section)
            }
        }
        return nil
    }
}
