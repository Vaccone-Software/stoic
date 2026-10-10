#if STOIC_METRICS
internal import Metrics
public import Stoic

/// Counts Stoic's events with swift-metrics.
///
/// Every event increments a counter named `stoic_events_total`, dimensioned
/// by event name and level (and by label, if asked: labels can be many, and
/// a metrics backend pays for every distinct series). Retries exhausted,
/// circuits opened, children restarted and finalizers abandoned become
/// alertable rates without any per-primitive wiring.
public struct SwiftMetricsInstrumentation: Instrumentation {
    public let counterLabel: String
    public let includeLabels: Bool

    public init(counterLabel: String = "stoic_events_total", includeLabels: Bool = false) {
        self.counterLabel = counterLabel
        self.includeLabels = includeLabels
    }

    public func record(_ event: Event) {
        var dimensions = [("name", event.name.rawValue), ("level", "\(event.level)")]
        if includeLabels, let label = event.label { dimensions.append(("label", label)) }
        Counter(label: counterLabel, dimensions: dimensions).increment()
    }
}
#endif
