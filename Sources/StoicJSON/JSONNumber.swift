/// A JSON number that remembers exactly what was written.
///
/// JSON's grammar says nothing about precision, and the two common readers
/// disagree: most parsers push every number through `Double` and quietly turn
/// `9007199254740993` into `9007199254740992`. A validation layer cannot
/// afford that, because "is this identifier in range" must be answered about
/// the number the sender wrote. So a `JSONNumber` is its source text, and
/// every numeric view of it says whether it is exact.
///
/// - Equality is numeric, not textual: `1`, `1.0`, `1e0` and `10e-1` are the
///   same number, and `-0` equals `0`. The canonical encoding writes them all
///   the same way, so a value survives a round trip through it. Compare
///   ``lexeme`` when the spelling matters.
/// - Order is numeric and exact at any precision: `9007199254740993` is
///   above `9007199254740992`, which no comparison through a `Double` can
///   say.
/// - Nothing here is ever NaN or infinite, and nothing is out of range. JSON
///   cannot spell NaN or infinity, and a decimal whose magnitude is outside
///   what a `Double` can hold (`1e400`, or `1e-400`, which would round to
///   zero) is refused by the parser and by ``init(lexeme:)`` alike, so every
///   `JSONNumber` has a ``double`` and every encoding of one parses back.
public struct JSONNumber: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The number exactly as it was written (or, for numbers built from Swift
    /// values, in canonical form).
    public let lexeme: String

    /// Wraps a lexeme that is already known to match the JSON grammar.
    init(validatedLexeme: String) {
        lexeme = validatedLexeme
    }

    /// Reads `lexeme` as a JSON number, or returns `nil` if it is not one
    /// under RFC 8259's grammar (no leading `+`, no leading zeros, digits on
    /// both sides of a decimal point, no hex, no `NaN` or `Infinity`) or if
    /// it is outside the range of a `Double`, as the parser would refuse it.
    ///
    /// Range is checked here as well as in the parser because a number that
    /// could be built but not parsed would break the promise every encoding
    /// makes: that its text parses back to an equal value.
    public init?(lexeme: String) {
        let bytes = Array(lexeme.utf8)
        guard case .success(let end) = scanJSONNumber(bytes, from: 0), end == bytes.count else {
            return nil
        }
        self.lexeme = lexeme
        guard double != nil else { return nil }
    }

    /// The canonical number for an integer.
    public init<Integer: FixedWidthInteger>(_ value: Integer) {
        lexeme = String(value)
    }

    /// The canonical number for a `Double`: the shortest digits that read
    /// back as the same value, laid out the way RFC 8785 lays them out.
    /// Negative zero keeps its sign (`-0`). Returns `nil` for NaN and the
    /// infinities, which JSON cannot represent.
    public init?(_ value: Double) {
        guard value.isFinite else { return nil }
        if value == 0 {
            lexeme = value.sign == .minus ? "-0" : "0"
            return
        }
        // `Double.description` is the shortest round-trip form; reading its
        // digits back and re-laying them out gives the JSON spelling.
        lexeme = NumberParts(lexeme: value.description).canonicalLexeme()
    }

    public var description: String { lexeme }

    // MARK: Views

    /// Whether the number was written as an integer: no fraction and no
    /// exponent. `1.0` and `1e2` are not integers in this sense, even though
    /// their values are integral; see ``hasIntegralValue``.
    public var isInteger: Bool {
        for byte in lexeme.utf8 where byte == 0x2E || byte == 0x65 || byte == 0x45 {
            return false
        }
        return true
    }

    /// Whether the value is a whole number, however it was written.
    public var hasIntegralValue: Bool {
        parts.integralMagnitudeDigitCount != nil
    }

    /// The value as an `Int64`, if the number was written as an integer and
    /// fits. Never rounds, never truncates.
    public var int64: Int64? {
        isInteger ? integralInt64 : nil
    }

    /// The value as a `UInt64`, if the number was written as an integer and
    /// fits. A negative number, other than `-0`, has no `UInt64`.
    public var uint64: UInt64? {
        isInteger ? integralUInt64 : nil
    }

    /// Like ``int64``, but also accepts integral values written with a
    /// fraction or exponent (`1.0`, `1e2`). For layers that choose to be
    /// lenient about spelling; the strict view is ``int64``.
    public var integralInt64: Int64? {
        let parts = parts
        guard let magnitude = parts.integralMagnitude else { return nil }
        if parts.negative {
            if magnitude <= UInt64(Int64.max) + 1 {
                return Int64(truncatingIfNeeded: 0 &- magnitude)
            }
            return nil
        }
        return magnitude <= UInt64(Int64.max) ? Int64(magnitude) : nil
    }

    /// Like ``uint64``, but also accepts integral values written with a
    /// fraction or exponent.
    public var integralUInt64: UInt64? {
        let parts = parts
        guard let magnitude = parts.integralMagnitude else { return nil }
        return parts.negative && magnitude != 0 ? nil : magnitude
    }

    /// The nearest `Double`, or `nil` when the number is outside what a
    /// `Double` can represent.
    ///
    /// Out of range means overflow (`1e400`) and also underflow to zero of a
    /// nonzero number (`1E-400`). Treating the second like the first keeps
    /// one rule: a number is in range exactly when it converts to a finite
    /// `Double` and is zero only if it was written as zero. Subnormals are in
    /// range. The result is the correctly rounded nearest value, so it may
    /// differ from the written number; ask ``isExactlyRepresentableAsDouble``.
    ///
    /// The parser and ``init(lexeme:)`` refuse out-of-range numbers, so for
    /// any `JSONNumber` that exists this is never `nil`; it stays optional
    /// because it is the check they use.
    ///
    /// Range is decided by the number, never by the length of its text: a
    /// lexeme too long for the standard library's conversion (which gives up
    /// somewhere past ten thousand digits) is judged by its exponent and
    /// converted from its leading digits, which round the same way.
    public var double: Double? {
        if lexeme.utf8.count <= Self.directConversionLimit {
            guard let value = Double(lexeme), value.isFinite else { return nil }
            if value == 0, !parts.digits.isEmpty { return nil }
            return value
        }
        let parts = parts
        if parts.digits.isEmpty { return lexeme.utf8.first == UInt8(ascii: "-") ? -0.0 : 0 }
        // 10^309 overflows; anything below 10^-324 rounds to zero.
        guard parts.exponent <= 308, parts.exponent >= -324 else { return nil }
        guard let value = Double(parts.roundingLexeme()), value.isFinite, value != 0 else { return nil }
        return value
    }

    /// The longest lexeme converted as written; past it, ``double`` goes
    /// through ``NumberParts/roundingLexeme()``.
    private static let directConversionLimit = 800

    /// Whether ``double`` carries the written number without losing a digit.
    ///
    /// "Exact" here means the shortest decimal that identifies the `Double`
    /// is the same number as the lexeme. By that rule `0.1` is exact (every
    /// reader who writes `0.1` means the double nearest it, and prints it
    /// back as `0.1`), `9007199254740993` is not (the nearest double prints
    /// as `9007199254740992`), and neither is `0.30000000000000004999`.
    /// `false` when the number is out of range.
    public var isExactlyRepresentableAsDouble: Bool {
        guard let value = double else { return false }
        if value == 0 { return true }
        return NumberParts(lexeme: value.description) == parts
    }

    /// The canonical spelling: what ``JSONValue/encoded(style:)`` writes for
    /// `.canonical`.
    ///
    /// Digits are the shortest that carry the number (so for any number a
    /// `Double` holds exactly, this is RFC 8785's ECMAScript formatting:
    /// `1e+21`, `1e-7`, `-0` as `0`). Where a `Double` could not hold the
    /// number, the same layout is applied to all its digits, so canonical
    /// text never loses precision that the source had.
    public var canonicalLexeme: String {
        parts.canonicalLexeme()
    }

    var parts: NumberParts { NumberParts(lexeme: lexeme) }

    // MARK: Equality

    public static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        lhs.lexeme == rhs.lexeme || lhs.parts == rhs.parts
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(parts)
    }

    // MARK: Order

    /// Numeric order on the digits, exact however many there are.
    public static func < (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        NumberParts.compare(lhs.parts, rhs.parts) < 0
    }

    /// Whether this number is a whole multiple of `step`, decided on the
    /// digits: `0.3` is a multiple of `0.1`, which no `Double` division says,
    /// and a number with a thousand digits is judged exactly, not rounded
    /// into one that passes. Zero is a multiple of everything; nothing is a
    /// multiple of zero. The sign of `step` does not matter.
    public func isMultiple(of step: JSONNumber) -> Bool {
        parts.isMultiple(of: step.parts)
    }
}

// MARK: - Decimal normal form

/// A number reduced to sign, significant digits and exponent, so that two
/// spellings of one value compare equal and any value can be laid out
/// canonically without going through a `Double`.
struct NumberParts: Hashable {
    /// Never true for zero, so `-0` and `0` are one value.
    var negative: Bool
    /// Significant digits (0...9), without leading or trailing zeros.
    /// Empty for zero.
    var digits: [UInt8]
    /// Decimal exponent of the first digit: the value is
    /// `d.ddd × 10^exponent`. Zero for zero.
    var exponent: Int

    /// Exponents beyond this are saturated; far past anything a `Double`
    /// holds, and small enough that adding a digit count cannot overflow.
    /// Only a lexeme on its way to being refused as out of range gets here.
    private static let exponentCap = 1 << 40

    /// Reads a lexeme that matches the JSON number grammar.
    init(lexeme: String) {
        var negative = false
        var digits: [UInt8] = []
        var integerDigits = 0
        var inFraction = false
        var exponentValue = 0
        var exponentNegative = false
        var inExponent = false

        for byte in lexeme.utf8 {
            switch byte {
            case UInt8(ascii: "-"):
                if inExponent { exponentNegative = true } else { negative = true }
            case UInt8(ascii: "+"):
                break
            case UInt8(ascii: "."):
                inFraction = true
            case UInt8(ascii: "e"), UInt8(ascii: "E"):
                inExponent = true
            default:
                let digit = Int(byte) - 0x30
                if inExponent {
                    exponentValue = min(exponentValue * 10 + digit, Self.exponentCap)
                } else {
                    digits.append(UInt8(truncatingIfNeeded: digit))
                    if !inFraction { integerDigits += 1 }
                }
            }
        }

        // value = 0.d1d2d3... × 10^pointPosition
        var pointPosition = integerDigits + (exponentNegative ? -exponentValue : exponentValue)
        var leading = 0
        while leading < digits.count, digits[leading] == 0 { leading += 1 }
        if leading == digits.count {
            self.negative = false
            self.digits = []
            exponent = 0
            return
        }
        digits.removeFirst(leading)
        pointPosition -= leading
        while digits.last == 0 { digits.removeLast() }

        self.negative = negative
        self.digits = digits
        exponent = pointPosition - 1
    }

    /// The number of digits before the decimal point if the value is a whole
    /// number, else `nil`. Zero counts as whole (with no digits).
    var integralMagnitudeDigitCount: Int? {
        if digits.isEmpty { return 0 }
        guard exponent >= 0, digits.count <= exponent + 1 else { return nil }
        return exponent + 1
    }

    /// The absolute value of a whole number, if it fits in 64 bits.
    var integralMagnitude: UInt64? {
        guard let count = integralMagnitudeDigitCount else { return nil }
        if count == 0 { return 0 }
        guard count <= 20 else { return nil }
        var magnitude: UInt64 = 0
        for position in 0..<count {
            let digit = position < digits.count ? UInt64(digits[position]) : 0
            let (shifted, overflowedShift) = magnitude.multipliedReportingOverflow(by: 10)
            let (sum, overflowedSum) = shifted.addingReportingOverflow(digit)
            if overflowedShift || overflowedSum { return nil }
            magnitude = sum
        }
        return magnitude
    }

    /// -1, 0 or 1. Signs first, then the position of the first digit, then
    /// the digits themselves: normal forms compare like that without any
    /// arithmetic.
    static func compare(_ a: NumberParts, _ b: NumberParts) -> Int {
        let signA = a.digits.isEmpty ? 0 : (a.negative ? -1 : 1)
        let signB = b.digits.isEmpty ? 0 : (b.negative ? -1 : 1)
        if signA != signB { return signA < signB ? -1 : 1 }
        if signA == 0 { return 0 }
        var order = 0
        if a.exponent != b.exponent {
            order = a.exponent < b.exponent ? -1 : 1
        } else {
            for (x, y) in zip(a.digits, b.digits) where x != y {
                order = x < y ? -1 : 1
                break
            }
            if order == 0, a.digits.count != b.digits.count { order = a.digits.count < b.digits.count ? -1 : 1 }
        }
        return order * signA
    }

    /// Whether the value is a whole multiple of `step`.
    ///
    /// A multiple of a step whose last digit is in the 10^p place is an
    /// integer times 10^p, so its own last digit cannot be further right.
    /// Counted in units of 10^p both are integers (the step its digits, the
    /// value its digits and some zeros), and long division a digit at a time
    /// keeps only the remainder, so no number is ever built.
    func isMultiple(of step: NumberParts) -> Bool {
        if digits.isEmpty { return true }
        if step.digits.isEmpty { return false }
        let last = exponent - (digits.count - 1)
        let stepLast = step.exponent - (step.digits.count - 1)
        guard last >= stepLast else { return false }
        var remainder = Remainder(dividingBy: step.digits)
        for digit in digits { remainder.append(digit) }
        for _ in 0..<(last - stepLast) { remainder.append(0) }
        return remainder.isZero
    }

    /// Significant digits enough to round any decimal to the nearest
    /// `Double`: a halfway point between two doubles has at most 767.
    private static let roundingDigits = 800

    /// A short lexeme that rounds to the same `Double` as the whole number:
    /// its first ``roundingDigits`` digits and, if any were cut, a final `1`.
    /// No halfway point lies strictly between the cut number and the whole
    /// one, and the `1` keeps the cut number off a halfway point it might
    /// equal, so the two round alike.
    func roundingLexeme() -> String {
        var out: [UInt8] = []
        if negative { out.append(UInt8(ascii: "-")) }
        out.append(contentsOf: [UInt8(ascii: "0"), UInt8(ascii: ".")])
        for digit in digits.prefix(Self.roundingDigits) { out.append(digit + 0x30) }
        if digits.count > Self.roundingDigits { out.append(UInt8(ascii: "1")) }
        out.append(UInt8(ascii: "e"))
        out.append(contentsOf: Array(String(exponent + 1).utf8))
        return String(decoding: out, as: UTF8.self)
    }

    /// RFC 8785 (ECMAScript `Number::toString`) layout of the digits.
    func canonicalLexeme() -> String {
        if digits.isEmpty { return "0" }
        var out: [UInt8] = []
        if negative { out.append(UInt8(ascii: "-")) }
        let k = digits.count
        let n = exponent + 1
        func emit(_ slice: ArraySlice<UInt8>) {
            for digit in slice { out.append(digit + 0x30) }
        }
        if k <= n, n <= 21 {
            emit(digits[...])
            out.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: n - k))
        } else if 0 < n, n <= 21 {
            emit(digits[..<n])
            out.append(UInt8(ascii: "."))
            emit(digits[n...])
        } else if -6 < n, n <= 0 {
            out.append(contentsOf: [UInt8(ascii: "0"), UInt8(ascii: ".")])
            out.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: -n))
            emit(digits[...])
        } else {
            emit(digits[..<1])
            if k > 1 {
                out.append(UInt8(ascii: "."))
                emit(digits[1...])
            }
            out.append(UInt8(ascii: "e"))
            let power = n - 1
            out.append(power < 0 ? UInt8(ascii: "-") : UInt8(ascii: "+"))
            out.append(contentsOf: Array(String(power.magnitude).utf8))
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// The remainder of a long division by a fixed divisor, fed the dividend one
/// decimal digit at a time.
///
/// A divisor of up to 37 digits keeps the remainder in a `UInt128` (ten times
/// it plus a digit still fits); a longer one, which only a hand-built step
/// has, keeps it as digits and subtracts.
private struct Remainder {
    private let divisor: [UInt8]
    private let small: UInt128?
    private var value: UInt128 = 0
    /// The remainder as digits, most significant first, no leading zeros.
    private var digits: [UInt8] = []

    init(dividingBy divisor: [UInt8]) {
        self.divisor = divisor
        if divisor.count <= 37 {
            var small: UInt128 = 0
            for digit in divisor { small = small * 10 + UInt128(digit) }
            self.small = small
        } else {
            small = nil
        }
    }

    var isZero: Bool { small == nil ? digits.isEmpty : value == 0 }

    mutating func append(_ digit: UInt8) {
        if let small {
            value = (value * 10 + UInt128(digit)) % small
            return
        }
        if !digits.isEmpty || digit != 0 { digits.append(digit) }
        // Below ten times the divisor, so at most nine subtractions.
        while !Self.isLess(digits, divisor) { Self.subtract(divisor, from: &digits) }
    }

    private static func isLess(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a.count != b.count { return a.count < b.count }
        for (x, y) in zip(a, b) where x != y { return x < y }
        return false
    }

    private static func subtract(_ b: [UInt8], from a: inout [UInt8]) {
        var borrow: UInt8 = 0
        var index = a.count - 1
        var other = b.count - 1
        while index >= 0 {
            let take = (other >= 0 ? b[other] : 0) + borrow
            if a[index] >= take {
                a[index] -= take
                borrow = 0
            } else {
                a[index] = a[index] + 10 - take
                borrow = 1
            }
            index -= 1
            other -= 1
        }
        let leading = a.firstIndex { $0 != 0 } ?? a.count
        a.removeFirst(leading)
    }
}

// MARK: - Grammar

/// Why a number failed to scan: the byte offset of the problem and what was
/// expected there.
struct NumberScanFailure: Error {
    var offset: Int
    var reason: String
}

/// Scans one JSON number starting at `start`, returning the offset just past
/// it. The grammar is RFC 8259's, with nothing extra:
/// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
///
/// A number must not run straight into a letter or a dot (`0x10`, `1.5.3`,
/// `1e5e3`): those are malformed numbers, and saying so is a better
/// diagnostic than a stray-character error one byte later.
func scanJSONNumber(_ bytes: [UInt8], from start: Int) -> Result<Int, NumberScanFailure> {
    let count = bytes.count
    var index = start

    func isDigit(_ at: Int) -> Bool {
        at < count && bytes[at] >= 0x30 && bytes[at] <= 0x39
    }

    if index < count, bytes[index] == UInt8(ascii: "-") { index += 1 }
    guard isDigit(index) else {
        return .failure(NumberScanFailure(offset: index, reason: "expected a digit"))
    }
    if bytes[index] == UInt8(ascii: "0") {
        index += 1
        if isDigit(index) {
            return .failure(NumberScanFailure(offset: index, reason: "leading zeros are not allowed"))
        }
    } else {
        while isDigit(index) { index += 1 }
    }
    if index < count, bytes[index] == UInt8(ascii: ".") {
        index += 1
        guard isDigit(index) else {
            return .failure(NumberScanFailure(offset: index, reason: "expected a digit after the decimal point"))
        }
        while isDigit(index) { index += 1 }
    }
    if index < count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
        index += 1
        if index < count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        guard isDigit(index) else {
            return .failure(NumberScanFailure(offset: index, reason: "expected a digit in the exponent"))
        }
        while isDigit(index) { index += 1 }
    }
    if index < count {
        let byte = bytes[index]
        let isLetter = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        if isLetter || byte == UInt8(ascii: ".") {
            return .failure(NumberScanFailure(offset: index, reason: "unexpected character after the number"))
        }
    }
    return .success(index)
}
