internal import StoicJSON

/// A JSON number as sign, whole-number coefficient and power of ten, so that
/// bounds and multiples can be compared without a `Double` in the middle.
///
/// `Double` cannot say whether `9007199254740993` is above `9007199254740992`
/// (they are the same double), nor whether `0.3` is a multiple of `0.1`
/// (`0.3 / 0.1` is `2.9999999999999996`). A range check that answers those
/// wrongly is a validator that lets an off-by-one identifier through or
/// rejects a number the file's author wrote correctly. Decimal digits make
/// both questions exact, for numbers of up to 38 significant digits; beyond
/// that (nobody's bound) the comparison falls back to `Double`.
struct ExactDecimal: Sendable, Hashable {
    var isNegative: Bool
    /// Digits without trailing zeros; zero is `0` with exponent 0.
    var coefficient: UInt128
    /// The value is `coefficient × 10^exponent`.
    var exponent: Int

    /// `nil` when the number has more than 38 significant digits or an
    /// exponent too large to reason about.
    init?(_ number: JSONNumber) {
        var negative = false
        var digits: [UInt8] = []
        var scale = 0  // digits after the decimal point
        var exponentValue = 0
        var seenPoint = false
        var inExponent = false
        var exponentNegative = false
        var exponentDigits = 0
        for byte in number.lexeme.utf8 {
            if inExponent {
                switch byte {
                case UInt8(ascii: "-"): exponentNegative = true
                case UInt8(ascii: "+"): break
                default:
                    exponentDigits += 1
                    guard exponentDigits <= 6 else { return nil }
                    exponentValue = exponentValue * 10 + Int(byte - 0x30)
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "-"): negative = true
            case UInt8(ascii: "."): seenPoint = true
            case UInt8(ascii: "e"), UInt8(ascii: "E"): inExponent = true
            default:
                if seenPoint { scale += 1 }
                digits.append(byte - 0x30)
            }
        }
        var start = 0
        while start < digits.count, digits[start] == 0 { start += 1 }
        var end = digits.count
        var trailing = 0
        while end > start, digits[end - 1] == 0 {
            end -= 1
            trailing += 1
        }
        let significant = digits[start..<end]
        guard significant.count <= 38 else { return nil }
        var value: UInt128 = 0
        for digit in significant { value = value * 10 + UInt128(digit) }
        if value == 0 {
            isNegative = false
            coefficient = 0
            exponent = 0
            return
        }
        isNegative = negative
        coefficient = value
        exponent = (exponentNegative ? -exponentValue : exponentValue) - scale + trailing
    }

    var isZero: Bool { coefficient == 0 }

    /// Decimal digits in the coefficient.
    private var digitCount: Int {
        var count = 0
        var rest = coefficient
        while rest > 0 {
            count += 1
            rest /= 10
        }
        return count
    }

    /// The position of the leading digit: `10^(magnitude - 1) <= |x| < 10^magnitude`.
    private var magnitude: Int { digitCount + exponent }

    private static func power(_ exponent: Int) -> UInt128? {
        var result: UInt128 = 1
        for _ in 0..<exponent {
            let (next, overflow) = result.multipliedReportingOverflow(by: 10)
            if overflow { return nil }
            result = next
        }
        return result
    }

    /// -1, 0 or 1.
    static func compare(_ a: ExactDecimal, _ b: ExactDecimal) -> Int {
        if a.isZero && b.isZero { return 0 }
        if a.isZero { return b.isNegative ? 1 : -1 }
        if b.isZero { return a.isNegative ? -1 : 1 }
        if a.isNegative != b.isNegative { return a.isNegative ? -1 : 1 }
        let sign = a.isNegative ? -1 : 1
        if a.magnitude != b.magnitude { return a.magnitude < b.magnitude ? -sign : sign }
        // Same leading position: bring both to the smaller exponent. The
        // larger-exponent side has at most as many digits as the other
        // after scaling, so this cannot overflow 38 digits.
        let low = min(a.exponent, b.exponent)
        func byCoefficient() -> Int {
            a.coefficient < b.coefficient ? -sign : (a.coefficient == b.coefficient ? 0 : sign)
        }
        guard let scaleA = power(a.exponent - low), let scaleB = power(b.exponent - low) else {
            return byCoefficient()
        }
        let (x, overflowA) = a.coefficient.multipliedReportingOverflow(by: scaleA)
        let (y, overflowB) = b.coefficient.multipliedReportingOverflow(by: scaleB)
        if overflowA || overflowB { return byCoefficient() }
        return x < y ? -sign : (x == y ? 0 : sign)
    }

    /// Whether `a / b` is a whole number, or `nil` if the digits do not fit.
    static func isMultiple(_ a: ExactDecimal, of b: ExactDecimal) -> Bool? {
        if a.isZero { return true }
        if b.isZero { return false }
        let low = min(a.exponent, b.exponent)
        guard let scaleA = power(a.exponent - low), let scaleB = power(b.exponent - low) else { return nil }
        let (x, ox) = a.coefficient.multipliedReportingOverflow(by: scaleA)
        let (y, oy) = b.coefficient.multipliedReportingOverflow(by: scaleB)
        if ox || oy { return nil }
        return x % y == 0
    }
}

extension JSONNumber {
    /// -1, 0 or 1: exact for numbers of up to 38 significant digits, nearest
    /// `Double` otherwise.
    func compared(to other: JSONNumber) -> Int {
        if let a = ExactDecimal(self), let b = ExactDecimal(other) {
            return ExactDecimal.compare(a, b)
        }
        let a = Double(lexeme) ?? 0
        let b = Double(other.lexeme) ?? 0
        return a < b ? -1 : (a == b ? 0 : 1)
    }

    /// Whether this number is a whole multiple of `step` (which is not zero).
    func isMultiple(of step: JSONNumber) -> Bool {
        if let a = ExactDecimal(self), let b = ExactDecimal(step), let exact = ExactDecimal.isMultiple(a, of: b) {
            return exact
        }
        let a = Double(lexeme) ?? 0
        let b = Double(step.lexeme) ?? 1
        let quotient = a / b
        return abs(quotient - quotient.rounded()) <= 1e-9 * max(1, abs(quotient))
    }

    /// Whether the value is zero, however it was written.
    var isZero: Bool {
        ExactDecimal(self)?.isZero ?? (Double(lexeme) == 0)
    }
}
