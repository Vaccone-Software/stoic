#if STOIC_CRYPTO
import Foundation
@testable import StoicSealed
import Testing

/// How fast values seal and open, printed for a person to read. Nothing here
/// gates on time (a shared machine drifts): the only assertions are that every
/// value that was sealed opened to what it was.
@Suite("Sealing throughput")
struct ThroughputTests {
    static let context = SealContext("bench.value", "id")

    /// Seconds for `body`, run `repetitions` times.
    static func seconds(_ repetitions: Int, _ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        let elapsed = try clock.measure { for _ in 0..<repetitions { try body() } }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test(arguments: [(label: "1 KB", size: 1_000, repetitions: 20_000), (label: "1 MB", size: 1_000_000, repetitions: 200)])
    func sealAndOpenReportTheirSpeed(label: String, size: Int, repetitions: Int) throws {
        let key = SealingKey.generate()
        let plaintext = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 5) }
        var sealed = try Sealing.seal(plaintext, context: Self.context, key: key)

        let sealing = try Self.seconds(repetitions) { sealed = try Sealing.seal(plaintext, context: Self.context, key: key) }
        var opened: [UInt8] = []
        let opening = try Self.seconds(repetitions) { opened = try Sealing.open(sealed, context: Self.context, key: key) }
        #expect(opened == plaintext)

        let megabytes = Double(size) * Double(repetitions) / 1_000_000
        func rate(_ elapsed: Double) -> String { "\(Int((megabytes / elapsed).rounded())) MB/s (\((elapsed / Double(repetitions) * 1e7).rounded() / 10) µs each)" }
        let line = "\(label): seal \(rate(sealing)), open \(rate(opening))"
        print("throughput \(line)")
    }
}
#endif
