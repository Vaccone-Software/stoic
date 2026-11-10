/// A short code a person can read to support, matching the event that
/// recorded the failure (design/31).
///
/// Ten characters of Crockford's base32, shown as two groups of five
/// (`K7Q2M-9XD4F`): 50 bits, short enough to read aloud over a phone. At a
/// million presented failures a day, two share a reference about once in six
/// years, and support matches on the reference and the day.
///
/// It is drawn from the ambient random source, so a seeded test sees the
/// same references on every run. Reading one back is forgiving, because a
/// person types what they heard: case does not matter, hyphens and spaces
/// are ignored, `O` reads as `0` and `I` and `L` as `1`.
public struct SupportReference: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The 50 bits.
    let value: UInt64

    /// Crockford's alphabet: no `I`, `L`, `O` or `U`, so nothing reads as
    /// another symbol.
    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let symbols = 10
    private static let mask: UInt64 = (1 << 50) - 1

    init(value: UInt64) {
        self.value = value & Self.mask
    }

    /// A new reference, from the ambient random source.
    public static func make(fileID: String = #fileID, line: UInt = #line) -> SupportReference {
        let source = Ambient.current.random
        var generator = source.generator(discriminator: source.nextDraw(), fileID: fileID, line: line)
        return SupportReference(value: generator.next())
    }

    /// The reference a person read back, or nil when it is not one.
    ///
    /// Case does not matter; hyphens and spaces are ignored; `O` reads as
    /// `0`, and `I` and `L` as `1`, as Crockford's base32 prescribes.
    public init?(_ text: String) {
        var value: UInt64 = 0
        var count = 0
        for character in text.uppercased() {
            if character == "-" || character == " " { continue }
            let symbol: Character = switch character {
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
            guard let digit = Self.alphabet.firstIndex(of: symbol), count < Self.symbols else { return nil }
            value = value << 5 | UInt64(digit)
            count += 1
        }
        guard count == Self.symbols else { return nil }
        self.value = value
    }

    /// `K7Q2M-9XD4F`.
    public var description: String {
        var text = ""
        for index in 0..<Self.symbols {
            if index == 5 { text.append("-") }
            let shift = UInt64(5 * (Self.symbols - 1 - index))
            text.append(Self.alphabet[Int(value >> shift & 31)])
        }
        return text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let reference = SupportReference(text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(text)\" is not a support reference (ten symbols of Crockford's base32)")
        }
        self = reference
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
