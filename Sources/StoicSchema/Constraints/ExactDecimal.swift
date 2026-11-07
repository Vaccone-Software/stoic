internal import StoicJSON

/// A JSON number as sign, whole-number coefficient and power of ten, when it
/// has at most 38 significant digits: the shape of a Foundation `Decimal`.
///
/// Bounds and multiples do not need this: `JSONNumber` orders and divides on
/// its digits at any precision. It exists for ``Schema/decimal(_:acceptingStrings:)``,
/// which must refuse a number a `Decimal` cannot hold and must check that the
/// `Decimal` it built has exactly the digits it was given.
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
        var exponentNegative = false
        var exponentDigits = 0
        for element in NumberLexemeScanner(number.lexeme) {
            switch element {
            case .minus(in: .exponent):
                exponentNegative = true
            case .minus:
                negative = true
            case .digit(let digit, in: .integer):
                digits.append(digit)
            case .digit(let digit, in: .fraction):
                scale += 1
                digits.append(digit)
            case .digit(let digit, in: .exponent):
                exponentDigits += 1
                guard exponentDigits <= 6 else { return nil }
                exponentValue = exponentValue * 10 + Int(digit)
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
}
