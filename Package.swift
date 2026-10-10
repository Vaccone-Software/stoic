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

// The lint tool's own build setting: present only when a consumer (or a
// developer running `swift build --traits Lint`) opts in. SwiftPM builds
// every target of a package it builds, trait or no trait, so the lint
// sources compile to nothing without it. See design/13.
let lintTrait: Set<String> = ["Lint"]
let lintDefine: SwiftSetting = .define("STOIC_LINT", .when(traits: lintTrait))
let swiftSyntax: [Target.Dependency] = [
    .product(name: "SwiftSyntax", package: "swift-syntax", condition: .when(traits: lintTrait)),
    .product(name: "SwiftParser", package: "swift-syntax", condition: .when(traits: lintTrait)),
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
        .library(name: "StoicUIKit", targets: ["StoicUIKit"]),
        .library(name: "StoicObservability", targets: ["StoicObservability"]),
        .library(name: "StoicJSON", targets: ["StoicJSON"]),
        .library(name: "StoicSchema", targets: ["StoicSchema"]),
        .library(name: "StoicSchemaTesting", targets: ["StoicSchemaTesting"]),
        .library(name: "StoicStore", targets: ["StoicStore"]),
        .library(name: "StoicSettings", targets: ["StoicSettings"]),
        // The build-tool plugin and the command it runs (design/13). Both
        // need the `Lint` trait: `.package(url: …, traits: ["Lint"])`.
        .executable(name: "stoic-lint", targets: ["stoic-lint"]),
        .plugin(name: "StoicLint", targets: ["StoicLint"]),
    ],
    traits: [
        .trait(
            name: "Lint",
            description: "Build the StoicLint plugin and its stoic-lint tool. Pulls in swift-syntax, which is fetched only when this trait is enabled."
        ),
        .trait(name: "Logging", description: "Send Stoic's events to swift-log (StoicObservability). Fetches swift-log only when enabled."),
        .trait(name: "Metrics", description: "Count Stoic's events with swift-metrics (StoicObservability). Fetches swift-metrics only when enabled."),
        .default(enabledTraits: []),
    ],
    dependencies: [
        // Used only by targets conditioned on the `Lint` trait, so a
        // consumer that does not enable it never fetches swift-syntax.
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.16.0"),
        .package(url: "https://github.com/apple/swift-metrics", from: "2.12.0"),
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
        // The Swift Testing glue for SchemaSuite. The suite itself lives in
        // StoicSchema and asserts nothing, so the library that apps ship
        // never links a test framework; this target is for test bundles.
        .target(name: "StoicSchemaTesting", dependencies: ["StoicSchema", "StoicJSON"], swiftSettings: strict),
        .testTarget(
            name: "StoicSchemaTests", dependencies: ["StoicSchema", "StoicSchemaTesting", "StoicJSON"],
            swiftSettings: strict),
        .testTarget(name: "StoicTests", dependencies: ["Stoic", "StoicTesting"], swiftSettings: strict),
        // AppKit lifecycle: finishing async shutdown before a Mac app quits.
        // Empty on platforms without AppKit.
        .target(name: "StoicAppKit", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(name: "StoicAppKitTests", dependencies: ["StoicAppKit", "StoicTesting"], swiftSettings: strict),
        // Foundation integration: platform errors that classify themselves
        // for retry, and HTTP status semantics.
        .target(name: "StoicApple", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(name: "StoicAppleTests", dependencies: ["StoicApple", "StoicTesting"], swiftSettings: strict),
        // UIKit lifecycle: background work bounded by the time the system
        // grants. Empty on platforms without UIKit.
        .target(name: "StoicUIKit", dependencies: ["Stoic"], swiftSettings: strict),
        // Adapters to the server ecosystem's observability APIs, each behind
        // its own trait so nobody fetches a package they did not ask for.
        .target(
            name: "StoicObservability",
            dependencies: [
                "Stoic",
                .product(name: "Logging", package: "swift-log", condition: .when(traits: ["Logging"])),
                .product(name: "Metrics", package: "swift-metrics", condition: .when(traits: ["Metrics"])),
            ],
            swiftSettings: strict + [
                .define("STOIC_LOGGING", .when(traits: ["Logging"])),
                .define("STOIC_METRICS", .when(traits: ["Metrics"])),
            ]
        ),
        .testTarget(
            name: "StoicObservabilityTests",
            dependencies: [
                "StoicObservability", "Stoic",
                .product(name: "Logging", package: "swift-log", condition: .when(traits: ["Logging"])),
                .product(name: "Metrics", package: "swift-metrics", condition: .when(traits: ["Metrics"])),
            ],
            swiftSettings: strict + [
                .define("STOIC_LOGGING", .when(traits: ["Logging"])),
                .define("STOIC_METRICS", .when(traits: ["Metrics"])),
            ]
        ),

        // The lint rules: pure functions from source text to findings, over
        // SwiftSyntax. No file system, no process, so every rule is testable
        // from an inline string.
        .target(name: "StoicLintCore", dependencies: swiftSyntax, swiftSettings: strict + [lintDefine]),
        // The command line around the rules, in the format Xcode and SwiftPM
        // parse. A host tool: it never links into an app.
        .executableTarget(name: "stoic-lint", dependencies: ["StoicLintCore"], swiftSettings: strict + [lintDefine]),
        // Runs stoic-lint over a target's Swift sources on every build and
        // fails the build on findings. Attach it with
        // `plugins: [.plugin(name: "StoicLint", package: "stoic")]`.
        .plugin(name: "StoicLint", capability: .buildTool(), dependencies: ["stoic-lint"]),
        .testTarget(
            name: "StoicLintCoreTests",
            dependencies: ["StoicLintCore"] + swiftSyntax,
            swiftSettings: strict + [lintDefine]
        ),
        // Persistence (design/15): atomic file writes, a crash-consistent
        // journal and an outbox, over a FileSystem protocol that a simulated
        // file system can replace to test every crash point. Foundation-free.
        .target(name: "StoicStore", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(name: "StoicStoreTests", dependencies: ["StoicStore", "StoicTesting"], swiftSettings: strict),
        // Settings: a schema-declared value kept in an atomic file, migrated,
        // validated and observable (design/18).
        .target(name: "StoicSettings", dependencies: ["Stoic", "StoicSchema", "StoicStore", "StoicJSON"], swiftSettings: strict),
        .testTarget(
            name: "StoicSettingsTests", dependencies: ["StoicSettings", "StoicSchema", "StoicStore", "StoicTesting"],
            swiftSettings: strict),
    ]
)
