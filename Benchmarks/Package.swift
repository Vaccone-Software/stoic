// swift-tools-version: 6.4
import PackageDescription

// Micro-benchmarks of Stoic's hot paths: `swift run -c release`.
let package = Package(
    name: "StoicBenchmarks",
    platforms: [.macOS(.v27)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "StoicBenchmarks",
            dependencies: [.product(name: "Stoic", package: "stoic")],
            swiftSettings: [.treatAllWarnings(as: .error), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
    ]
)
