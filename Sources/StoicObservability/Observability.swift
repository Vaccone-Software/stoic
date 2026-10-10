// Adapters from Stoic's events to the server ecosystem's observability APIs.
//
// Each adapter is compiled only when its trait is enabled, so depending on
// this product costs nothing until an app asks for an integration:
//
//     .package(url: "…/stoic", from: "…", traits: ["Logging", "Metrics"])
//
// - `Logging`: `SwiftLogInstrumentation` (swift-log).
// - `Metrics`: `SwiftMetricsInstrumentation` (swift-metrics).
