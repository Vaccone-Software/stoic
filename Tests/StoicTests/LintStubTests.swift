import Foundation
import StoicTesting
import Testing

/// design/13: the plugin is attached to a target but Stoic was not built with
/// the `Lint` trait. SwiftPM builds every target of a package, so the tool
/// exists as a stub; it must fail the build with the way out, not pass quietly.
@Suite("stoic-lint: built without the Lint trait")
struct LintStubTests {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var tool: URL? {
        let build = root.appending(path: ".build")
        // The test runner sits in the products directory on Linux, wherever
        // `--build-path` put it; elsewhere this finds nothing and the rest apply.
        var candidates = [Bundle.main.bundleURL, build.appending(path: "out/Products/Debug"), build.appending(path: "debug")]
        if let triples = try? FileManager.default.contentsOfDirectory(atPath: build.path()) {
            candidates += triples.map { build.appending(path: "\($0)/debug") }
        }
        return candidates.map { $0.appending(path: "stoic-lint") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path()) }
    }

    @Test(.failureMode("design/13", "the plugin is attached but the Lint trait is off"))
    func theStubFailsTheBuildAndSaysHowToGetTheTool() throws {
        let tool = try #require(Self.tool, "stoic-lint is not built")
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--output", "/dev/null", "Sources"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // Under `swift test --traits Lint` this is the real tool, whose
        // behaviour StoicLintCoreTests covers; the stub exists only without it.
        let isStub = output.contains("built without the Lint trait")
        if !isStub, output.contains("no such file or directory") { return }   // the real tool
        #expect(isStub, "expected the stub, got: \(output)")
        #expect(process.terminationStatus == 2)
        #expect(output.contains("traits: [\"Lint\"]"))
    }
}
