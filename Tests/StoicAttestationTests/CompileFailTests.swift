#if STOIC_ATTESTATION
import Foundation
import StoicTesting
import Testing

/// What must not compile with StoicAttestation (scripts/compile-fail/attestation),
/// compiled through SIL against the trait build's modules, as the kernel's
/// fixtures are (Tests/StoicTests/CompileFailTests.swift).
@Suite("App Attest: what does not compile", .serialized)
struct AttestationCompileFailTests {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var products: URL? {
        let build = root.appending(path: ".build")
        var candidates = [Bundle.main.bundleURL, build.appending(path: "out/Products/Debug"), build.appending(path: "debug")]
        if let triples = try? FileManager.default.contentsOfDirectory(atPath: build.path()) {
            candidates += triples.map { build.appending(path: "\($0)/debug") }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "StoicAttestation.swiftmodule").path()) }
    }

    static func compile(_ name: String) throws -> (compiled: Bool, errors: String) {
        guard let products else {
            Issue.record("no built StoicAttestation module under \(root.path())/.build")
            return (false, "")
        }
        let process = Process()
        #if canImport(Darwin)
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        #else
        process.executableURL = URL(filePath: "/usr/bin/env")
        #endif
        process.arguments = [
            "swiftc", "-emit-sil", "-o", "/dev/null",
            "-I", products.path(), "-I", products.appending(path: "Modules").path(),
            "-swift-version", "6",
            "-enable-upcoming-feature", "ExistentialAny", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
            root.appending(path: "scripts/compile-fail/attestation/\(name).swift").path(),
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus == 0, output.split(separator: "\n").filter { $0.contains("error:") }.joined(separator: "\n"))
    }

    static func expectRefusal(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let text = try String(contentsOf: root.appending(path: "scripts/compile-fail/attestation/\(name).swift"), encoding: .utf8)
        let expected = try #require(text.split(separator: "\n").first { $0.hasPrefix("// expect-error: ") }
            .map { String($0.dropFirst("// expect-error: ".count)) }, sourceLocation: sourceLocation)
        let outcome = try compile(name)
        #expect(!outcome.compiled, "\(name) compiled, but must not", sourceLocation: sourceLocation)
        #expect(outcome.errors.contains(expected), "\(name) failed, but not with \"\(expected)\":\n\(outcome.errors)", sourceLocation: sourceLocation)
    }

    @Test func theControlCompiles() throws {
        let outcome = try Self.compile("attestation-control")
        #expect(outcome.compiled, "the harness is broken: \(outcome.errors)")
    }

    @Test(.failureMode("design/29", "an attested request is passed where a person must be authenticated"),
          arguments: ["attested-as-principal", "attested-policy-principal"])
    func anAttestedRequestIsNotAPerson(_ name: String) throws {
        try Self.expectRefusal(name)
    }

    @Test(arguments: ["mint-app-attested", "mint-key-attested"])
    func onlyTheVerifierMintsAttestationEvidence(_ name: String) throws {
        try Self.expectRefusal(name)
    }
}
#endif
