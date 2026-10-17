#if STOIC_CRYPTO
import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import Testing

/// What an exploration of crash points found.
struct CrashReport: CustomStringConvertible {
    var name: String
    /// The number of file operations the run performed; crash points are 0...this.
    var operationCount = 0
    /// Distinct post-crash disks the check was run on.
    var images = 0
    var violations: [String] = []

    var description: String {
        "\(name): \(operationCount + 1) crash points, \(images) crash images, \(violations.count) violations"
            + violations.prefix(5).map { "\n  - \($0)" }.joined()
    }
}

/// Runs a download against a simulated disk, then dies after every file
/// operation it performed, in every way the simulated hardware allows (design/15:
/// any subset of what was not synced, torn at any byte), and lets `check`
/// look at what recovery finds.
///
/// - Parameters:
///   - setup: Builds the disk before the download; whatever it leaves is made
///     durable first.
///   - operation: The download under test. It reports through
///     `disk.checkpoint("returned")` when the download has returned to its
///     caller, which is when "placed" must be true.
///   - check: Looks at a crash image: whether the download had returned
///     before the machine died, and the image. Returns what is wrong, if anything.
func exploreDownloadCrashes(
    _ name: String,
    samples: Int = 4,
    setup: (SimulatedFileSystem) throws -> Void,
    operation: (SimulatedFileSystem) async throws -> Void,
    check: (SimulatedFileSystem, _ returned: Bool) async throws -> String?
) async throws -> CrashReport {
    let disk = SimulatedFileSystem()
    try setup(disk)
    disk.settle()
    try await operation(disk)
    var report = CrashReport(name: name)
    report.operationCount = disk.operationCount
    let operations = disk.operations
    let returnedAt = disk.checkpoints.first { $0.label == "returned" }?.operationCount ?? Int.max
    for point in 0...disk.operationCount {
        for image in disk.crashImages(afterOperation: point, samples: samples, seed: UInt64(point)) {
            report.images += 1
            let problem: String?
            do {
                problem = try await check(image.fileSystem, point >= returnedAt)
            } catch {
                problem = "the check threw \(error)"
            }
            if let problem {
                let after = point == 0 ? "the start" : operations[point - 1].description
                report.violations.append("crash point \(point) (after \(after)): \(problem)\n    disk: \(image.description)")
            }
        }
    }
    return report
}

/// A downloader of `data` from a server that honours ranges, over `disk`, as an app does after a restart.
func recover(_ disk: SimulatedFileSystem, data: [UInt8], request: Download, policy: DownloadPolicy) async throws -> DownloadResult {
    let transport = ScriptedTransport()
    transport.on(.get("/model.bin"), respond: [.serving(Resource(data, etag: "\"v1\""), chunkSize: 700)])
    let client = HTTPClient(base: modelsBase, transport: transport)
    return try await Downloader(client: client, fileSystem: disk, policy: policy, label: "recovery").download(request)
}
#endif
