// Duration arithmetic that clamps instead of trapping.
//
// `Duration` traps on overflow, and schedule math reaches overflow honestly:
// an exponential backoff at attempt 130 is 2^130 times its base. Every
// duration Stoic computes from user-supplied numbers goes through these.

extension Duration {
    /// The longest representable duration.
    static let maximum = Duration(attoseconds: .max)

    /// The most negative representable duration.
    static let minimum = Duration(attoseconds: .min)

    /// `self + other`, clamped to the representable range.
    func saturatingAdding(_ other: Duration) -> Duration {
        let (sum, overflow) = attoseconds.addingReportingOverflow(other.attoseconds)
        guard overflow else { return Duration(attoseconds: sum) }
        return other > .zero ? .maximum : .minimum
    }

    /// `self - other`, clamped to the representable range.
    func saturatingSubtracting(_ other: Duration) -> Duration {
        let (difference, overflow) = attoseconds.subtractingReportingOverflow(other.attoseconds)
        guard overflow else { return Duration(attoseconds: difference) }
        return other < .zero ? .maximum : .minimum
    }

    /// `self × factor`, clamped to the representable range. Not-a-number is zero.
    func saturatingMultiplied(by factor: Double) -> Duration {
        guard !factor.isNaN else { return .zero }
        let product = Double(attoseconds) * factor
        if product >= Double(Int128.max) { return .maximum }
        if product <= Double(Int128.min) { return .minimum }
        return Duration(attoseconds: Int128(product))
    }

    /// The duration as a floating-point number of seconds.
    var seconds: Double {
        Double(attoseconds) / 1e18
    }

    /// `self` clamped into `range`.
    func clamped(to range: ClosedRange<Duration>) -> Duration {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
