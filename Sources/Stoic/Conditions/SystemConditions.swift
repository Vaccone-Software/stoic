/// What the device is going through: memory pressure, heat, power saving.
///
/// Robust code adapts to the machine it runs on. A phone that is hot, low on
/// memory or saving battery should not retry as eagerly as one that is
/// idle and plugged in: every retry costs energy and heat, and an
/// aggressive backoff on a struggling device makes the struggle worse.
/// Stoic reads the current conditions from the ambient context, and its
/// backoff (``retry(_:budget:classify:nesting:clock:label:fileID:line:operation:)``
/// and ``Supervisor`` restarts) stretches with ``backoffFactor``.
///
/// The core knows conditions only as a value; `StoicApple` provides a
/// source that reads the real ones (thermal state, Low Power Mode, memory
/// pressure). Tests set them directly.
public struct SystemConditions: Sendable, Hashable, CustomStringConvertible {
    /// How hard the system is pressing for memory.
    public enum MemoryPressure: Int, Sendable, Hashable, Comparable {
        case normal, warning, critical
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// How hot the device is, in the platform's own four steps.
    public enum Thermal: Int, Sendable, Hashable, Comparable {
        case nominal, fair, serious, critical
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var memoryPressure: MemoryPressure
    public var thermal: Thermal
    public var lowPowerMode: Bool

    public init(memoryPressure: MemoryPressure = .normal, thermal: Thermal = .nominal, lowPowerMode: Bool = false) {
        self.memoryPressure = memoryPressure
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
    }

    /// Nothing unusual.
    public static let normal = SystemConditions()

    /// How much to stretch backoff delays: 1 when all is well, doubling for
    /// a serious thermal state, Low Power Mode or memory warnings, and
    /// quadrupling at critical levels. The factors multiply, capped at 8.
    public var backoffFactor: Double {
        var factor = 1.0
        switch thermal {
        case .nominal, .fair: break
        case .serious: factor *= 2
        case .critical: factor *= 4
        }
        if lowPowerMode { factor *= 2 }
        switch memoryPressure {
        case .normal: break
        case .warning: factor *= 2
        case .critical: factor *= 4
        }
        return min(factor, 8)
    }

    public var description: String {
        "conditions(memory: \(memoryPressure), thermal: \(thermal), lowPower: \(lowPowerMode))"
    }
}

/// Where the current conditions come from.
public protocol SystemConditionsSource: Sendable {
    var current: SystemConditions { get }
}

/// Conditions that never change: the default, and the usual test source.
public struct FixedConditions: SystemConditionsSource {
    public let current: SystemConditions

    public init(_ conditions: SystemConditions = .normal) {
        self.current = conditions
    }
}
