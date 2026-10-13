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
///
/// **Spans.** Each `span.ended` event (``withSpan(_:_:fileID:line:operation:)``)
/// also records its duration into a `Timer` named `stoic_span_duration`,
/// dimensioned by the span's `name` and `status` (`ok`, `error`,
/// `cancelled`): latency and failure rate per operation, with no wiring at
/// the call site. A span's name is a metric dimension, so keep names
/// low-cardinality and put the varying part in an attribute.
public struct SwiftMetricsInstrumentation: Instrumentation {
    public let counterLabel: String
    public let includeLabels: Bool
    /// The timer spans are recorded into; `nil` records none.
    public let spanTimerLabel: String?

    public init(
        counterLabel: String = "stoic_events_total", includeLabels: Bool = false,
        spanTimerLabel: String? = "stoic_span_duration"
    ) {
        self.counterLabel = counterLabel
        self.includeLabels = includeLabels
        self.spanTimerLabel = spanTimerLabel
    }

    public func record(_ event: Event) {
        var dimensions = [("name", event.name.rawValue), ("level", "\(event.level)")]
        if includeLabels, let label = event.label { dimensions.append(("label", label)) }
        Counter(label: counterLabel, dimensions: dimensions).increment()
        if let spanTimerLabel, event.name == "span.ended" { recordSpan(event, label: spanTimerLabel) }
    }

    private func recordSpan(_ event: Event, label: String) {
        guard case .duration(let duration)? = event["duration"], case .string(let name)? = event["name"] else { return }
        var status = "ok"
        if case .string(let reported)? = event["status"] { status = reported }
        let parts = duration.components
        let nanoseconds = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let total = nanoseconds.overflow ? Int64.max : nanoseconds.partialValue &+ parts.attoseconds / 1_000_000_000
        Timer(label: label, dimensions: [("name", name), ("status", status)]).recordNanoseconds(max(0, total))
    }
}
#endif
