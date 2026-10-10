public import Stoic
internal import Foundation
internal import Dispatch
internal import Synchronization

/// The device's real conditions: thermal state and Low Power Mode from
/// `ProcessInfo`, memory pressure from a Dispatch memory-pressure source.
///
/// Install it once at launch so every retry and supervisor in the app backs
/// off further on a struggling device:
///
///     try await withAmbient({ $0.conditions = DeviceConditions.shared }) {
///         try await app.run()
///     }
///
/// Thermal state and Low Power Mode are read when asked; memory pressure is
/// remembered from the last event, and relaxes back to normal a minute after
/// the last warning, because the system announces pressure but not its end.
public final class DeviceConditions: SystemConditionsSource {
    /// The process-wide source.
    public static let shared = DeviceConditions()

    private struct Pressure {
        var level: SystemConditions.MemoryPressure = .normal
        var at: ContinuousClock.Instant?
    }

    private final class PressureCell: Sendable {
        let state = Mutex(Pressure())
    }

    private let pressure = PressureCell()
    private let source: any DispatchSourceMemoryPressure

    private init() {
        let pressure = pressure
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        self.source = source
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            let level: SystemConditions.MemoryPressure =
                event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            pressure.state.withLock { $0 = Pressure(level: level, at: .now) }
        }
        source.activate()
    }

    public var current: SystemConditions {
        let info = ProcessInfo.processInfo
        let thermal: SystemConditions.Thermal
        switch info.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }
        let memory = pressure.state.withLock { pressure -> SystemConditions.MemoryPressure in
            guard let at = pressure.at, at.duration(to: .now) < .seconds(60) else { return .normal }
            return pressure.level
        }
        return SystemConditions(memoryPressure: memory, thermal: thermal, lowPowerMode: info.isLowPowerModeEnabled)
    }
}
