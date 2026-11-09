// swift-tools-version: 6.4
import PackageDescription

// The real-process check of StoicXPC (design/25, Testing): an app and its
// bundled service, built from this package's products and assembled into an
// app bundle by scripts/xpc-integration.sh, which runs the app.
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
    name: "xpc-integration",
    platforms: [.macOS(.v27)],
    dependencies: [.package(path: "../..")],
    targets: [
        // What both sides import: the methods and the build.
        .target(name: "IntegrationAPI", dependencies: [.product(name: "StoicXPC", package: "stoic"), .product(name: "Stoic", package: "stoic")],
                swiftSettings: strict),
        .executableTarget(name: "IntegrationService", dependencies: ["IntegrationAPI", .product(name: "StoicXPC", package: "stoic"), .product(name: "Stoic", package: "stoic")],
                          swiftSettings: strict),
        .executableTarget(name: "IntegrationApp", dependencies: ["IntegrationAPI", .product(name: "StoicXPC", package: "stoic"), .product(name: "Stoic", package: "stoic")],
                          swiftSettings: strict),
    ]
)
