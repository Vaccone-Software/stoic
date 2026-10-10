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

    /// `self × factor`, clamped to the representable range. Not-a-number
    /// (including zero × infinity) is zero. Integral factors are exact.
    func saturatingMultiplied(by factor: Double) -> Duration {
        guard !factor.isNaN else { return .zero }
        if factor.rounded() == factor, abs(factor) < 1e18 {
            let (product, overflow) = attoseconds.multipliedReportingOverflow(by: Int128(factor))
            if !overflow { return Duration(attoseconds: product) }
            return (attoseconds < 0) == (factor < 0) ? .maximum : .minimum
        }
        let product = Double(attoseconds) * factor
        guard !product.isNaN else { return .zero }
        if product >= Double(Int128.max) { return .maximum }
        if product <= Double(Int128.min) { return .minimum }
        return Duration(attoseconds: Int128(product))
    }

    /// The furthest Stoic will schedule a timer: a century. Underlying clocks
    /// trap on instants they cannot represent, so a longer wait — a deadline
    /// of `Duration.maximum`, meaning "no deadline" — is a wait for this
    /// long, which in practice is a wait for cancellation.
    static let horizon = Duration.seconds(100 * 365 * 24 * 3600)

    /// The duration as a floating-point number of seconds.
    var seconds: Double {
        Double(attoseconds) / 1e18
    }

    /// `self` clamped into `range`.
    func clamped(to range: ClosedRange<Duration>) -> Duration {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
