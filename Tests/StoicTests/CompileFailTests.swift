import Foundation
import StoicTesting
import Testing

/// Swift Testing cannot assert that code fails to compile, so these tests ask
/// the compiler: each file in `scripts/compile-fail` is compiled through SIL
/// against the module under test, exactly as `scripts/check.sh` does. A file
/// whose first line is `// expect-error: <text>` must fail with an error
/// containing <text>; the control, which has none, must compile, so an
/// expected failure cannot pass because the module was not found.
@Suite("Compile-fail", .serialized)
struct CompileFailTests {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The directory holding the built `Stoic` module: whichever build
    /// layout (Xcode build system or the native one) produced this run.
    static var products: URL? {
        let build = root.appending(path: ".build")
        var candidates = [build.appending(path: "out/Products/Debug"), build.appending(path: "debug")]
        if let triples = try? FileManager.default.contentsOfDirectory(atPath: build.path()) {
            candidates += triples.map { build.appending(path: "\($0)/debug") }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "Stoic.swiftmodule").path()) }
    }

    struct Outcome {
        let compiled: Bool
        let errors: String
    }

    static func compile(_ name: String) throws -> Outcome {
        guard let products else {
            Issue.record("no built Stoic module under \(root.path())/.build")
            return Outcome(compiled: false, errors: "")
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-emit-sil", "-o", "/dev/null",
            "-I", products.path(), "-I", products.appending(path: "Modules").path(),
            "-swift-version", "6",
            "-enable-upcoming-feature", "ExistentialAny", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
            root.appending(path: "scripts/compile-fail/\(name).swift").path(),
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let errors = output.split(separator: "\n").filter { $0.contains("error:") }.joined(separator: "\n")
        return Outcome(compiled: process.terminationStatus == 0, errors: errors)
    }

    static func expectedError(in name: String) throws -> String? {
        let text = try String(contentsOf: root.appending(path: "scripts/compile-fail/\(name).swift"), encoding: .utf8)
        return text.split(separator: "\n").first { $0.hasPrefix("// expect-error: ") }
            .map { String($0.dropFirst("// expect-error: ".count)) }
    }

    @Test func theControlCompiles() throws {
        let outcome = try Self.compile("control")
        #expect(outcome.compiled, "the harness is broken: \(outcome.errors)")
    }

    @Test(.failureMode("design/04", "someone tries to keep the Scope"),
          arguments: ["keep-scope-in-a-variable", "return-scope-from-body", "escape-scope-into-task",
                      "escape-task-scope-into-task", "escape-saga-into-task"])
    func aScopeHandleCannotEscapeItsBody(_ name: String) throws {
        let found = try Self.expectedError(in: name)
        let expected = try #require(found)
        let outcome = try Self.compile(name)
        #expect(!outcome.compiled, "\(name) compiled, but must not")
        #expect(outcome.errors.contains(expected), "\(name) failed, but not with \"\(expected)\":\n\(outcome.errors)")
    }

    @Test(.failureMode("design/02", "the schedule is unbounded"))
    func retryRefusesAnUnboundedSchedule() throws {
        let found = try Self.expectedError(in: "retry-unbounded-schedule")
        let expected = try #require(found)
        let outcome = try Self.compile("retry-unbounded-schedule")
        #expect(!outcome.compiled, "retry accepted an unbounded schedule")
        #expect(outcome.errors.contains(expected), "failed, but not with \"\(expected)\":\n\(outcome.errors)")
    }
}
