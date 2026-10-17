#if STOIC_CRYPTO
import Foundation
@testable import StoicSealed
import StoicStore
import Synchronization

/// A keyring in a fresh in-memory custody, and the custody beside it.
func makeRing(name: String = "test.keyring", custody: InMemoryKeyCustody = InMemoryKeyCustody()) throws -> (ring: Keyring, custody: InMemoryKeyCustody) {
    (try Keyring.open(name: name, custody: custody, ifMissing: .create).keyring, custody)
}

/// Lowercase hexadecimal.
func hexString(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    return String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] })
}

func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

/// A fresh directory under the system temporary directory, removed when the
/// test is done with it.
struct TempDirectory: ~Copyable {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "stoic-sealed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> String { path + "/" + name }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A value shared between test closures behind a lock.
final class SendableBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value { storage.withLock { $0 } }

    func mutate(_ body: (inout Value) -> Void) { storage.withLock { body(&$0) } }

    func mutateReturning<R>(_ body: (inout Value) -> R) -> R { storage.withLock { body(&$0) } }
}

/// Whether `haystack` holds `needle` as a contiguous run.
func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    return (0...(haystack.count - needle.count)).contains { start in
        haystack[start..<start + needle.count].elementsEqual(needle)
    }
}

/// Every file on a simulated disk that holds `marker` anywhere in its bytes.
func filesHolding(_ marker: [UInt8], on disk: SimulatedFileSystem) -> [String] {
    disk.files.filter { contains($0.value, marker) }.map(\.key).sorted()
}

/// What a crash check may know about where the crash fell: which
/// checkpoints the operation had reported by then.
struct CrashPoint {
    let reported: [String]

    /// Whether the operation had reported `label` (by `disk.checkpoint(_:)`)
    /// before the machine died. Anything reported has happened.
    func reached(_ label: String) -> Bool { reported.contains(label) }

    /// How many reported labels start with `prefix`.
    func count(prefix: String) -> Int { reported.filter { $0.hasPrefix(prefix) }.count }
}

struct CrashReport: CustomStringConvertible {
    var name: String
    var crashPoints = 0
    var images = 0
    var violations: [String] = []

    var description: String { "\(name): \(crashPoints) crash points, \(images) crash images, \(violations.count) violations" }
}

/// Runs an operation on a simulated disk, then dies after every operation it
/// performed, in every way the simulated hardware allows, and checks what
/// recovery finds. (The harness of StoicStore's own tests, on the public API,
/// with one refinement: a checkpoint reported between operation *n* and *n+1*
/// is explored both as reached and as not, because something that is not a
/// file operation (a keyring written to its custody, which this simulation
/// does not model) can happen in that gap, and so can the crash.)
func exploreCrashes(
    _ name: String,
    setup: (SimulatedFileSystem) throws -> Void,
    operation: (SimulatedFileSystem) throws -> Void,
    check: (SimulatedFileSystem, CrashPoint) throws -> String?
) rethrows -> CrashReport {
    let disk = SimulatedFileSystem()
    try setup(disk)
    disk.settle()
    try operation(disk)

    var report = CrashReport(name: name)
    report.crashPoints = disk.operationCount + 1
    let operations = disk.operations
    let checkpoints = disk.checkpoints            // in the order they were reported
    for point in 0...disk.operationCount {
        let before = checkpoints.filter { $0.operationCount < point }.count
        let upTo = checkpoints.filter { $0.operationCount <= point }.count
        for reportedCount in before...upTo {
            let crash = CrashPoint(reported: checkpoints.prefix(reportedCount).map(\.label))
            for image in disk.crashImages(afterOperation: point, samples: 24, seed: UInt64(point)) {
                report.images += 1
                let outcome: String?
                do {
                    outcome = try check(image.fileSystem, crash)
                } catch {
                    outcome = "check threw \(error)"
                }
                if let outcome {
                    report.violations.append("crash point \(point) (after \(point == 0 ? "the start" : operations[point - 1].description), \(reportedCount) of \(checkpoints.count) checkpoints): \(outcome)\n    disk: \(image.description)")
                }
            }
        }
    }
    return report
}
#endif
