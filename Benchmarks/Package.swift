// swift-tools-version: 6.4
import Foundation
import PackageDescription

// Micro-benchmarks of Stoic's hot paths: `swift run -c release`.

// A path dependency's identity is its directory's name: "stoic" in a usual
// checkout, something else in a worktree or a CI mount.
let stoic = URL(fileURLWithPath: Context.packageDirectory).deletingLastPathComponent().lastPathComponent.lowercased()
let package = Package(
    name: "StoicBenchmarks",
    platforms: [.macOS(.v27)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(
            name: "StoicBenchmarks",
            dependencies: [.product(name: "Stoic", package: stoic)],
            swiftSettings: [.treatAllWarnings(as: .error), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
    ]
)
