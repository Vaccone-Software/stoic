// swift-tools-version: 6.4
import Foundation
import PackageDescription

// A runnable tour of Stoic: `swift run` in this directory.

// A path dependency's identity is its directory's name: "stoic" in a usual
// checkout, something else in a worktree or a CI mount.
let stoic = URL(fileURLWithPath: Context.packageDirectory).deletingLastPathComponent().deletingLastPathComponent()
    .lastPathComponent.lowercased()
let package = Package(
    name: "Tour",
    platforms: [.macOS(.v27)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "Tour",
            dependencies: [
                .product(name: "Stoic", package: stoic), .product(name: "StoicSchema", package: stoic),
                .product(name: "StoicJSON", package: stoic), .product(name: "StoicStore", package: stoic),
                .product(name: "StoicSettings", package: stoic),
            ],
            swiftSettings: [.treatAllWarnings(as: .error)]
        ),
    ]
)
