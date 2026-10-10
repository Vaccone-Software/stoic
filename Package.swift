// swift-tools-version: 6.4
import PackageDescription

// The settings every Stoic target is held to. A warning is an error here:
// a library that asks apps to be strict cannot ship code that is not.
// SwiftPM strips these from a package built as a dependency (SE-0480), so
// they bind Stoic's own sources only; apps opt in through their own
// manifest, and the lint plugin (design/13) carries the rest.
let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .strictMemorySafety(),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "stoic",
    // Swift 6.4's runtime (cancellation shields, async defer) ships with the
    // 27 releases. Nothing older is supported, so nothing older is emulated.
    platforms: [
        .macOS(.v27),
        .iOS(.v27),
        .tvOS(.v27),
        .watchOS(.v27),
        .visionOS(.v27),
    ],
    products: [
        .library(name: "Stoic", targets: ["Stoic"]),
        .library(name: "StoicTesting", targets: ["StoicTesting"]),
        .library(name: "StoicAppKit", targets: ["StoicAppKit"]),
        .library(name: "StoicApple", targets: ["StoicApple"]),
        .library(name: "StoicJSON", targets: ["StoicJSON"]),
        .library(name: "StoicSchema", targets: ["StoicSchema"]),
    ],
    // The core depends on the standard library and Synchronization alone.
    // Integrations (swift-log, swift-metrics, swift-distributed-tracing,
    // ServiceLifecycle) and the macro and lint products arrive as traits
    // and separate targets as their milestones land (DESIGN.md, Roadmap).
    targets: [
        .target(name: "Stoic", swiftSettings: strict),
        // Virtual clocks, seeded randomness and recorded events, for the
        // tests of anything built on Stoic. Never linked into an app.
        .target(name: "StoicTesting", dependencies: ["Stoic"], swiftSettings: strict),
        // A strict, Foundation-free JSON layer: the trust boundary under the
        // validation layer (design/06). It depends on the standard library
        // alone, so a schema can be checked anywhere Swift runs.
        .target(name: "StoicJSON", swiftSettings: strict),
        .testTarget(name: "StoicJSONTests", dependencies: ["StoicJSON"], swiftSettings: strict),
        // One declaration per type that decodes, encodes, validates and
        // documents it (design/06). Foundation-free, and it depends on
        // StoicJSON alone, so a schema runs anywhere Swift does.
        .target(name: "StoicSchema", dependencies: ["StoicJSON"], swiftSettings: strict),
        .testTarget(name: "StoicSchemaTests", dependencies: ["StoicSchema", "StoicJSON"], swiftSettings: strict),
        .testTarget(name: "StoicTests", dependencies: ["Stoic", "StoicTesting"], swiftSettings: strict),
        // AppKit lifecycle: finishing async shutdown before a Mac app quits.
        // Empty on platforms without AppKit.
        .target(name: "StoicAppKit", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(name: "StoicAppKitTests", dependencies: ["StoicAppKit", "StoicTesting"], swiftSettings: strict),
        // Foundation integration: platform errors that classify themselves
        // for retry, and HTTP status semantics.
        .target(name: "StoicApple", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(name: "StoicAppleTests", dependencies: ["StoicApple", "StoicTesting"], swiftSettings: strict),
    ]
)
