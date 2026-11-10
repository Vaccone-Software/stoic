// swift-tools-version: 6.4
import CompilerPluginSupport
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

// The sealed-storage library's build setting and its swift-crypto product:
// present only when `Crypto` is on, as `Lint` and `Macros` do theirs, so a
// consumer that never enables the trait never fetches swift-crypto (nor
// builds BoringSSL on Linux). See design/24.
let cryptoTrait: Set<String> = ["Crypto"]
let cryptoDefine: SwiftSetting = .define("STOIC_CRYPTO", .when(traits: cryptoTrait))
let crypto: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto", condition: .when(traits: cryptoTrait))
]

// The App Attest verifier's build setting and its products: present only
// when `Attestation` is on (which enables `Crypto`), so a consumer that never
// enables it never fetches swift-certificates. See design/29.
let attestationTrait: Set<String> = ["Attestation"]
let attestationDefine: SwiftSetting = .define("STOIC_ATTESTATION", .when(traits: attestationTrait))
let attestation: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto", condition: .when(traits: attestationTrait)),
    .product(name: "X509", package: "swift-certificates", condition: .when(traits: attestationTrait)),
    .product(name: "SwiftASN1", package: "swift-asn1", condition: .when(traits: attestationTrait)),
]

// The macros' build setting and their swift-syntax products: present only
// when `Macros` is on. The same arrangement as `Lint`, and for the same
// reason: SwiftPM builds every target of the package, so the macro sources
// compile to nothing without the define, and a consumer that never enables
// the trait never fetches swift-syntax. See design/06 (Layer 4).
let macrosTrait: Set<String> = ["Macros"]
let macrosDefine: SwiftSetting = .define("STOIC_MACROS", .when(traits: macrosTrait))
let macroSyntax: [Target.Dependency] = [
    .product(name: "SwiftSyntax", package: "swift-syntax", condition: .when(traits: macrosTrait)),
    .product(name: "SwiftSyntaxMacros", package: "swift-syntax", condition: .when(traits: macrosTrait)),
    .product(name: "SwiftSyntaxBuilder", package: "swift-syntax", condition: .when(traits: macrosTrait)),
    .product(name: "SwiftDiagnostics", package: "swift-syntax", condition: .when(traits: macrosTrait)),
    .product(name: "SwiftParser", package: "swift-syntax", condition: .when(traits: macrosTrait)),
    .product(name: "SwiftCompilerPlugin", package: "swift-syntax", condition: .when(traits: macrosTrait)),
]
let macroTestSupport: [Target.Dependency] = [
    .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax", condition: .when(traits: macrosTrait)),
    .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax", condition: .when(traits: macrosTrait)),
]

// The macros are declared apart from the rest: one manifest expression this
// size defeats the type checker.
let macroTargets: [Target] = [
    // Layer 4 of the validation design: the macros. The plugin is the
    // compiler plugin that expands them (swift-syntax, host only); the
    // library declares the attributes and depends on StoicSchema, which
    // is all the generated code calls.
    .macro(name: "StoicMacrosPlugin", dependencies: macroSyntax, swiftSettings: strict + [macrosDefine]),
    .target(
        name: "StoicMacros", dependencies: ["StoicSchema", "StoicMacrosPlugin"],
        swiftSettings: strict + [macrosDefine]),
    // Expansion tests: the macro's output, as text, for every shape of
    // input and every diagnostic.
    .testTarget(
        name: "StoicMacrosTests",
        dependencies: ["StoicMacrosPlugin"] + macroSyntax + macroTestSupport,
        swiftSettings: strict + [macrosDefine]),
    // Behaviour tests: types declared with the macros, compared with the
    // same schemas written by hand, and run through SchemaSuite.
    .testTarget(
        name: "StoicMacrosUsageTests",
        dependencies: ["StoicMacros", "StoicSchema", "StoicSchemaTesting", "StoicJSON", "Stoic", "StoicTesting"],
        swiftSettings: strict + [macrosDefine]),
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
        .library(name: "StoicFoundation", targets: ["StoicFoundation"]),
        .library(name: "StoicApple", targets: ["StoicApple"]),
        .library(name: "StoicUIKit", targets: ["StoicUIKit"]),
        .library(name: "StoicObservability", targets: ["StoicObservability"]),
        .library(name: "StoicJSON", targets: ["StoicJSON"]),
        .library(name: "StoicSchema", targets: ["StoicSchema"]),
        .library(name: "StoicSchemaTesting", targets: ["StoicSchemaTesting"]),
        // `@Schema`, `@Refined` and the constraint attributes (design/06,
        // Layer 4). Needs the `Macros` trait: `.package(url: …, traits: ["Macros"])`.
        .library(name: "StoicMacros", targets: ["StoicMacros"]),
        .library(name: "StoicStore", targets: ["StoicStore"]),
        .library(name: "StoicSettings", targets: ["StoicSettings"]),
        // Sealed storage (design/24): authenticated encryption for files and
        // journals, keys kept in the app's custody. Needs the `Crypto` trait:
        // `.package(url: …, traits: ["Crypto"])`.
        .library(name: "StoicSealed", targets: ["StoicSealed"]),
        // The Keychain (or any `SecretStore`) as the custody of a sealed
        // keyring: the one place StoicSealed and StoicApple meet. Needs the
        // `Crypto` trait, as StoicSealed does.
        .library(name: "StoicSealedKeychain", targets: ["StoicSealedKeychain"]),
        // The resilient HTTP client (design/19), with a scripted transport
        // for tests.
        .library(name: "StoicHTTP", targets: ["StoicHTTP"]),
        // Resumable, verified, durable file downloads (design/23), digests by
        // swift-crypto. Needs the `Crypto` trait: `.package(url: …, traits: ["Crypto"])`.
        .library(name: "StoicDownloads", targets: ["StoicDownloads"]),
        // Time (design/26): plain dates and times, zoned date-times resolved
        // by zone rules that can change under them, calendar periods, and
        // their text forms and schemas. Portable; Foundation only for the
        // system's zone rules and `Date`.
        .library(name: "StoicTime", targets: ["StoicTime"]),
        // Values that arrive for a screen and actions a person triggers
        // (design/31): Live and Action, main-actor Observation types.
        // Portable; a server never builds it.
        .library(name: "StoicLive", targets: ["StoicLive"]),
        // Calling a bundled XPC service (design/25): the service's lifecycle
        // explicit, every wait bounded, a handshake by build, and the host
        // the service runs. macOS only; empty elsewhere.
        .library(name: "StoicXPC", targets: ["StoicXPC"]),
        // App Attest as an HTTP authenticator (design/29): the one place
        // StoicApple (the key) and StoicHTTP (the client) meet. Apple
        // platforms; empty elsewhere.
        .library(name: "StoicAttestedHTTP", targets: ["StoicAttestedHTTP"]),
        // The server's App Attest verifier (design/29): attestations,
        // assertions, signed requests, challenges and the counter window,
        // portable. Needs the `Attestation` trait: `.package(url: …, traits: ["Attestation"])`.
        .library(name: "StoicAttestation", targets: ["StoicAttestation"]),
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
        .trait(
            name: "Macros",
            description: "Build the StoicMacros product (@Schema, @Refined). Pulls in swift-syntax, which is fetched only when this trait is enabled."
        ),
        .trait(
            name: "Crypto",
            description: "Build the libraries that use swift-crypto (StoicSealed, StoicDownloads). Pulls in swift-crypto, which is fetched only when this trait is enabled."
        ),
        .trait(
            name: "Attestation",
            description: "Build StoicAttestation, the App Attest verifier. Pulls in swift-certificates, and swift-crypto through Crypto, which are fetched only when this trait is enabled.",
            enabledTraits: ["Crypto"]
        ),
        .trait(name: "Logging", description: "Send Stoic's events to swift-log (StoicObservability). Fetches swift-log only when enabled."),
        .trait(name: "Metrics", description: "Count Stoic's events with swift-metrics (StoicObservability). Fetches swift-metrics only when enabled."),
        .default(enabledTraits: []),
    ],
    dependencies: [
        // Used only by targets conditioned on the `Lint` or `Macros` trait, so a
        // consumer that enables neither never fetches swift-syntax.
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "604.0.0"),
        // Used only by targets conditioned on the `Crypto` trait. On Apple
        // platforms `Crypto` is CryptoKit; elsewhere it is BoringSSL.
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"6.0.0"),
        // Used only by StoicAttestation, conditioned on the `Attestation` trait:
        // X.509 path validation (swift-certificates, whose 1.21 admits
        // swift-crypto 5) and the DER of the attestation's nonce (swift-asn1,
        // which swift-crypto already brings).
        .package(url: "https://github.com/apple/swift-certificates", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-asn1", from: "1.1.0"),
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
        .testTarget(name: "StoicJSONTests", dependencies: ["StoicJSON", "StoicTesting"], swiftSettings: strict),
        // One declaration per type that decodes, encodes, validates and
        // documents it (design/06). It depends on StoicJSON, and on
        // Foundation only for the leaves of Foundation's own types (`Date`,
        // `URL`, `UUID`, `Data`, `Decimal`) and the `Codable` leaf, which
        // live in Sources/StoicSchema/Foundation.
        .target(name: "StoicSchema", dependencies: ["StoicJSON"], swiftSettings: strict),
        // The Swift Testing glue for SchemaSuite. The suite itself lives in
        // StoicSchema and asserts nothing, so the library that apps ship
        // never links a test framework; this target is for test bundles.
        // It also reads compatibility fixtures beside a test (design/32), through
        // Foundation's files and environment.
        .target(name: "StoicSchemaTesting", dependencies: ["StoicSchema", "StoicJSON"], swiftSettings: strict),
        .testTarget(
            name: "StoicSchemaTests", dependencies: ["StoicSchema", "StoicSchemaTesting", "StoicJSON", "StoicTesting"],
            // Compatibility fixtures (design/32), read beside the test file.
            exclude: ["Compatibility"], swiftSettings: strict),
        .testTarget(name: "StoicTests", dependencies: ["Stoic", "StoicTesting"], swiftSettings: strict),
        // AppKit lifecycle: finishing async shutdown before a Mac app quits.
        // Empty on platforms without AppKit.
        .target(name: "StoicAppKit", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(name: "StoicAppKitTests", dependencies: ["StoicAppKit", "Stoic", "StoicTesting"], swiftSettings: strict),
        // Foundation integration: Foundation's own errors (URLError,
        // POSIXError, CocoaError) classified for retry. Portable: Foundation
        // ships on Linux, and nothing here needs an Apple framework.
        .target(name: "StoicFoundation", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(
            name: "StoicFoundationTests", dependencies: ["StoicFoundation", "Stoic", "StoicTesting"],
            // An app's `Stoic` table, for `String(localized:)` (design/31).
            resources: [.copy("Resources/Stoic.strings")], swiftSettings: strict),
        // Apple platform integration (design/21): network reachability,
        // background tasks, the Keychain, device conditions. Builds on
        // StoicFoundation, so its error table comes along.
        .target(name: "StoicApple", dependencies: ["Stoic", "StoicFoundation"], swiftSettings: strict),
        .testTarget(
            name: "StoicAppleTests", dependencies: ["StoicApple", "Stoic", "StoicTesting"],
            // Compatibility fixtures (design/32): what released builds wrote.
            exclude: ["Compatibility"], swiftSettings: strict),
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
            dependencies: ["StoicLintCore", "Stoic", "StoicTesting"] + swiftSyntax,
            swiftSettings: strict + [lintDefine]
        ),
        // Persistence (design/15): atomic file writes, a crash-consistent
        // journal and an outbox, over a FileSystem protocol that a simulated
        // file system can replace to test every crash point. Foundation-free.
        .target(name: "StoicStore", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(
            name: "StoicStoreTests", dependencies: ["StoicStore", "Stoic", "StoicJSON", "StoicSchema", "StoicSchemaTesting", "StoicTesting"],
            // Compatibility fixtures (design/32): what released builds wrote.
            exclude: ["Compatibility"], swiftSettings: strict),
        // Settings: a schema-declared value kept in an atomic file, migrated,
        // validated and observable (design/18).
        .target(name: "StoicSettings", dependencies: ["Stoic", "StoicSchema", "StoicStore", "StoicJSON"], swiftSettings: strict),
        .testTarget(
            name: "StoicSettingsTests",
            dependencies: ["StoicSettings", "Stoic", "StoicSchema", "StoicSchemaTesting", "StoicStore", "StoicJSON", "StoicTesting"],
            // Compatibility fixtures (design/32): what released builds wrote.
            exclude: ["Compatibility"], swiftSettings: strict),
        // Sealed storage (design/24): AES-256-GCM over swift-crypto for whole
        // files and journals, with the keys in a keyring the app keeps in its
        // own custody. Compiled only with the `Crypto` trait, so adopting the
        // other libraries fetches no cryptography package.
        .target(
            name: "StoicSealed",
            dependencies: ["Stoic", "StoicStore"] + crypto,
            swiftSettings: strict + [cryptoDefine]
        ),
        .testTarget(
            name: "StoicSealedTests",
            dependencies: ["StoicSealed", "Stoic", "StoicStore", "StoicTesting"] + crypto,
            swiftSettings: strict + [cryptoDefine]
        ),
        // The adapter that keeps a sealed keyring in a `SecretStore` (design/24),
        // so an app that uses the Keychain for its keys writes none. It is a
        // library of its own because it is the only code that needs both
        // StoicSealed (the trait, swift-crypto) and StoicApple: neither may
        // depend on the other.
        .target(
            name: "StoicSealedKeychain",
            dependencies: ["StoicSealed", "StoicApple"],
            swiftSettings: strict + [cryptoDefine]
        ),
        .testTarget(
            name: "StoicSealedKeychainTests",
            dependencies: ["StoicSealedKeychain", "StoicSealed", "StoicApple", "StoicTesting"],
            swiftSettings: strict + [cryptoDefine]
        ),
        // HTTP (design/19): per-host retry, breaker and bulkhead, idempotency
        // keys, bounded responses decoded through schemas, request
        // coalescing, over a transport that tests replace with a script.
        .target(
            name: "StoicHTTP", dependencies: ["Stoic", "StoicFoundation", "StoicSchema", "StoicJSON"], swiftSettings: strict),
        .testTarget(
            name: "StoicHTTPTests",
            dependencies: ["StoicHTTP", "Stoic", "StoicSchema", "StoicJSON", "StoicTesting"],
            swiftSettings: strict),
        // Downloads (design/23): resumable, verified, durable file transfers
        // over StoicHTTP's streaming and StoicStore's atomic placement. Its
        // digests come from swift-crypto, so it is behind the `Crypto` trait
        // with StoicSealed: nobody fetches a package they did not ask for.
        .target(
            name: "StoicDownloads",
            dependencies: ["Stoic", "StoicHTTP", "StoicStore"] + crypto,
            swiftSettings: strict + [cryptoDefine]
        ),
        .testTarget(
            name: "StoicDownloadsTests",
            dependencies: ["StoicDownloads", "Stoic", "StoicHTTP", "StoicStore", "StoicTesting"] + crypto,
            swiftSettings: strict + [cryptoDefine]
        ),
        // Time (design/26): the calendar types and the zone rules, beside the
        // kernel's `Moment` and wall clock. The system's rules come from
        // Foundation, in Sources/StoicTime/Foundation; everything else is
        // stdlib arithmetic over the offsets they give, tested on scripted
        // rules.
        .target(name: "StoicTime", dependencies: ["Stoic", "StoicSchema"], swiftSettings: strict),
        .testTarget(
            name: "StoicTimeTests", dependencies: ["StoicTime", "Stoic", "StoicSchema", "StoicSchemaTesting", "StoicTesting"],
            // Compatibility fixtures (design/32): what released builds wrote.
            exclude: ["Compatibility"], swiftSettings: strict),
        // Live values and actions (design/31): what a screen shows, joined by
        // key, and what a person triggers, guarded and keyed per intent. On
        // the kernel alone: TaskSlot, declared operations, presentations.
        .target(name: "StoicLive", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(name: "StoicLiveTests", dependencies: ["StoicLive", "Stoic", "StoicTesting"], swiftSettings: strict),
        // XPC services (design/25): the app's peer and the service's host,
        // over XPCSession and XPCListener, with an in-process simulated
        // service for tests. macOS only: the sources compile to nothing
        // elsewhere.
        .target(name: "StoicXPC", dependencies: ["Stoic"], swiftSettings: strict),
        .testTarget(name: "StoicXPCTests", dependencies: ["StoicXPC", "Stoic", "StoicTesting"], swiftSettings: strict),
        // App Attest on the device, as an HTTP authenticator (design/29): the
        // AppAttester from StoicApple signing StoicHTTP's requests, and the
        // wire protocol with the app's server. It meets both so that neither
        // depends on the other, as StoicSealedKeychain does for sealing.
        .target(name: "StoicAttestedHTTP", dependencies: ["Stoic", "StoicApple", "StoicHTTP", "StoicJSON"], swiftSettings: strict),
        .testTarget(
            name: "StoicAttestedHTTPTests",
            dependencies: ["StoicAttestedHTTP", "StoicApple", "StoicHTTP", "StoicJSON", "Stoic", "StoicTesting", "StoicAttestation"]
                + attestation,
            swiftSettings: strict + [attestationDefine]),
        // The server's verifier (design/29): compiled only with the
        // `Attestation` trait, so adopting the other libraries fetches no
        // certificate library. Portable: it runs where the app's server does.
        .target(name: "StoicAttestation", dependencies: ["Stoic"] + attestation, swiftSettings: strict + [attestationDefine]),
        .testTarget(
            name: "StoicAttestationTests",
            dependencies: ["StoicAttestation", "Stoic", "StoicTesting"] + attestation,
            exclude: ["Vectors"],
            swiftSettings: strict + [attestationDefine]),
    ] + macroTargets
)
