#if STOIC_LINT
import Foundation
import StoicLintCore
import StoicTesting
import Testing

/// The failure-mode rows of design/13 that live in the command line around the
/// rules, proved by running the built `stoic-lint` the way the plugin does.
@Suite("stoic-lint: the tool's failure modes", .serialized)
struct ToolFailureModeTests {
    struct Result {
        let status: Int32
        let output: String
    }

    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The built tool, whichever build layout produced this run.
    static var tool: URL? {
        let build = root.appending(path: ".build")
        var candidates = [build.appending(path: "out/Products/Debug"), build.appending(path: "debug")]
        if let triples = try? FileManager.default.contentsOfDirectory(atPath: build.path()) {
            candidates += triples.map { build.appending(path: "\($0)/debug") }
        }
        return candidates.map { $0.appending(path: "stoic-lint") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path()) }
    }

    /// A scratch directory for one test.
    static func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "stoic-lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func run(_ arguments: [String]) throws -> Result {
        let tool = try #require(tool, "stoic-lint is not built")
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// One `try!` on line 2: a single, easily counted finding.
    static let offender = "func f() {\n    let x = try! read()\n}\n"

    @Test(.failureMode("design/13", "a path does not exist"))
    func aMissingPathExitsTwo() throws {
        let directory = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try Self.run([directory.appending(path: "Nope.swift").path()])
        #expect(result.status == 2)
        #expect(result.output.contains("no such file or directory"))
    }

    @Test(.failureMode("design/13", "the same file is passed twice, or a directory and a file in it"))
    func aFileNamedTwiceIsLintedOnce() throws {
        let directory = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Sources/A.swift")
        try Self.write(Self.offender, to: file)
        let result = try Self.run([file.path(), file.path(), directory.path(), directory.appending(path: "Sources").path()])
        #expect(result.status == 1)
        #expect(result.output.components(separatedBy: "[stoic.force-try]").count - 1 == 1, "\(result.output)")
        #expect(result.output.contains("1 error(s) in 1 file(s)"))
    }

    @Test(.failureMode("design/13", "a file is not valid UTF-8"))
    func invalidUTF8IsDecodedLeniently() throws {
        let directory = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Bad.swift")
        // A stray 0xFF byte in a comment on line 1; the finding is on line 3.
        var bytes = Data("// caf".utf8)
        bytes.append(0xFF)
        bytes.append(Data("\nfunc f() {\n    let x = try! read()\n}\n".utf8))
        try bytes.write(to: file)
        let result = try Self.run([file.path()])
        #expect(result.status == 1)
        #expect(result.output.contains("Bad.swift:3:13: error: [stoic.force-try]"), "\(result.output)")
    }

    @Test(.failureMode("design/13", "the baseline file is missing or invalid"))
    func aBaselineThatCannotBeReadIsAnError() throws {
        let directory = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Clean.swift")
        try Self.write("let x = 1\n", to: file)

        let missing = try Self.run(["--baseline", directory.appending(path: "nope.json").path(), file.path()])
        #expect(missing.status == 2)
        #expect(missing.output.contains("cannot read baseline"))

        let invalid = directory.appending(path: "bad.json")
        try Self.write("{ not json", to: invalid)
        let broken = try Self.run(["--baseline", invalid.path(), file.path()])
        #expect(broken.status == 2)
        #expect(broken.output.contains("is not valid"))
    }

    @Test(.failureMode("design/13", "the tool fails after writing nothing"))
    func aFailingRunLeavesNoStamp() throws {
        let directory = try Self.workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "A.swift")
        let stamp = directory.appending(path: "work/A.stoic-lint-stamp")

        try Self.write(Self.offender, to: file)
        let failing = try Self.run(["--output", stamp.path(), file.path()])
        #expect(failing.status == 1)
        #expect(!FileManager.default.fileExists(atPath: stamp.path()), "a failing run must not leave a stamp: the build would trust it")

        // The control: once the finding is fixed, the same invocation writes it.
        try Self.write("let x = 1\n", to: file)
        let passing = try Self.run(["--output", stamp.path(), file.path()])
        #expect(passing.status == 0)
        #expect(FileManager.default.fileExists(atPath: stamp.path()))
    }
}

@Suite("stoic-lint: the rules' failure modes")
struct LintCoreFailureModeTests {
    @Test(.failureMode("design/13", "a source file has syntax errors"))
    func theRulesRunOnWhatParsed() {
        let source = """
            func broken( {
                let = = 1
            }

            func fine() {
                let x = try! read()
            }
            """
        // The parser recovers; the violation after the damage is still found.
        #expect(rules(in: source).contains("force-try"))
    }

    @Test(.failureMode("design/13", "a finding sits in generated code"))
    func generatedCodeIsNotSpecialCased() {
        let source = "func f() { let x = try! read() }\n"
        for path in ["/work/.build/plugins/outputs/App/DerivedSources/Generated.swift", "/work/Sources/App/Generated/Models.swift"] {
            #expect(rules(in: source, path: path) == ["force-try"], "\(path)")
        }
    }
}
#endif
