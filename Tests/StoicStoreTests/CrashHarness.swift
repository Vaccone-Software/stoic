@testable import StoicStore

/// What an exploration of crash points found.
struct CrashReport: CustomStringConvertible {
    var name: String
    /// The number of operations the run performed; crash points are 0...this.
    var operationCount = 0
    var crashPoints: Int { operationCount + 1 }
    /// Distinct post-crash file systems the check was run on.
    var images = 0
    /// Crashes *during recovery* that were checked as well (only for recoveries that write).
    var recoveryImages = 0
    var violations: [Violation] = []

    struct Violation: CustomStringConvertible {
        let crashPoint: Int
        let afterOperation: String
        let image: String
        let message: String

        var description: String {
            "crash point \(crashPoint) (after \(afterOperation)): \(message)\n    disk: \(image)"
        }
    }

    var description: String {
        "\(name): \(crashPoints) crash points, \(images) crash images, \(recoveryImages) recovery-crash images, \(violations.count) violations"
    }
}

/// What a check may know about where the crash fell.
struct CrashContext {
    let crashPoint: Int
    let checkpoints: [SimulatedFileSystem.Checkpoint]

    /// Whether the operation under test had reported `label` (by calling
    /// `checkpoint(label)`) before the machine died. Anything reported must
    /// have survived.
    func reached(_ label: String) -> Bool {
        checkpoints.contains { $0.label == label && $0.operationCount <= crashPoint }
    }

    /// How many checkpoints with this prefix had been reached.
    func count(prefix: String) -> Int {
        checkpoints.filter { $0.label.hasPrefix(prefix) && $0.operationCount <= crashPoint }.count
    }
}

/// Runs an operation against a simulated disk, then dies after every
/// operation it performed, in every way the simulated hardware allows, and
/// checks what recovery finds.
///
/// - Parameters:
///   - setup: Builds the starting disk. Whatever it leaves is made durable
///     before the operation begins.
///   - operation: The code under test. It calls `disk.checkpoint(_:)` when
///     something is acknowledged to the caller.
///   - recovery: What the app does on the next launch, run on each crash
///     image with its own crash points explored (a crash *during* recovery).
///     `nil` skips that level.
///   - check: Runs recovery on a crash image and returns a description of
///     what is wrong, or `nil`. It must not assume the image is the only one.
func exploreCrashes(
    _ name: String,
    samples: Int = 24,
    setup: (SimulatedFileSystem) async throws -> Void,
    operation: (SimulatedFileSystem) async throws -> Void,
    recovery: ((SimulatedFileSystem) async throws -> Void)? = nil,
    check: (SimulatedFileSystem, CrashContext) async throws -> String?
) async rethrows -> CrashReport {
    let disk = SimulatedFileSystem()
    try await setup(disk)
    disk.settle()
    try await operation(disk)

    var report = CrashReport(name: name)
    report.operationCount = disk.operationCount
    let operations = disk.operations
    let checkpoints = disk.checkpoints

    func verify(_ image: SimulatedFileSystem.CrashImage, point: Int, context: CrashContext, nested: Bool) async {
        let outcome: String?
        do {
            outcome = try await check(image.fileSystem, context)
        } catch {
            outcome = "check threw \(error)"
        }
        if let outcome {
            report.violations.append(.init(
                crashPoint: point,
                afterOperation: point == 0 ? "the start" : operations[point - 1].description,
                image: image.description + (nested ? " [then crashed during recovery]" : ""),
                message: outcome
            ))
        }
    }

    for point in 0...disk.operationCount {
        let context = CrashContext(crashPoint: point, checkpoints: checkpoints)
        for image in disk.crashImages(afterOperation: point, samples: samples, seed: UInt64(point)) {
            report.images += 1
            // Recovery runs inside `check`, so give the recovery crash its own copy.
            if let recovery {
                let copy = image.fileSystem.fork()
                copy.settle()
                if (try? await recovery(copy)) != nil, copy.operationCount > 0 {
                    for recoveryPoint in 0...copy.operationCount {
                        for nested in copy.crashImages(afterOperation: recoveryPoint, samples: 4, seed: UInt64(point * 1000 + recoveryPoint)) {
                            report.recoveryImages += 1
                            await verify(nested, point: point, context: context, nested: true)
                        }
                    }
                }
            }
            await verify(image, point: point, context: context, nested: false)
        }
    }
    return report
}
