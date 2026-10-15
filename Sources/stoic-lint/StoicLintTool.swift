#if STOIC_LINT
import Foundation
import StoicLintCore

/// The command line around the rules.
///
/// All judgment lives in `StoicLintCore`; this reads files, writes the
/// report and picks the exit code: 0 clean, 1 findings that fail the build,
/// 2 a problem running at all (bad arguments, unreadable file). Keeping
/// "your code is wrong" apart from "the tool could not run" lets a script
/// treat them differently.
@main
enum StoicLintTool {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let invocation: Invocation
        do {
            invocation = try Invocation.parse(arguments)
        } catch {
            fail("\(error)\n\n\(Invocation.usage)")
        }

        do {
            switch invocation.mode {
            case .help:
                print(Invocation.usage)
            case .writeBaseline(let path):
                try writeBaseline(to: path, inputs: invocation.inputs)
            case .lint:
                let status = try lint(invocation)
                exit(status)
            }
        } catch {
            fail("\(error)")
        }
    }

    // MARK: Modes

    private static func lint(_ invocation: Invocation) throws -> Int32 {
        let files = try sources(from: invocation.inputs)

        var baseline: Baseline?
        var baselineRoot = ""
        var baselinePath: String?
        if let path = invocation.baselinePath {
            let absolute = absolutePath(path)
            guard let data = FileManager.default.contents(atPath: absolute) else {
                throw ToolError("cannot read baseline \(absolute)")
            }
            do {
                baseline = try Baseline.decode(data)
            } catch {
                throw ToolError("baseline \(absolute) is not valid: \(error)")
            }
            baselineRoot = directory(of: absolute)
            baselinePath = absolute
        }

        let outcome = Linter().lint(files, baseline: baseline, baselineRoot: baselineRoot, baselinePath: baselinePath)
        print(outcome.report(), terminator: "")

        // The stamp exists to tell the build system "this ran and passed".
        // A failing run leaves it absent so the next build runs the tool
        // again instead of trusting an old pass.
        if outcome.exitCode == 0, let stamp = invocation.outputPath {
            try writeStamp(at: absolutePath(stamp), summary: outcome.summary)
        }
        return outcome.exitCode
    }

    private static func writeBaseline(to path: String, inputs: [String]) throws {
        let files = try sources(from: inputs)
        let absolute = absolutePath(path)
        let reports = files.map { Linter().analyze(source: $0.text, path: $0.path) }
        let findings = reports.flatMap(\.findings)
        let suppressed = reports.flatMap(\.suppressed)
        let baseline = Baseline(recording: findings, suppressed: suppressed, relativeTo: directory(of: absolute))
        try FileManager.default.createDirectory(
            atPath: directory(of: absolute), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: absolute, contents: try baseline.jsonData()) else {
            throw ToolError("cannot write baseline \(absolute)")
        }
        print(
            "stoic-lint: recorded \(findings.count) finding(s) and \(suppressed.count) suppression(s) from \(files.count) file(s) in \(absolute)")
    }

    // MARK: Files

    /// The Swift files named by `inputs`, directories expanded, in a stable
    /// order. Hidden directories (`.build`, `.git`) are skipped.
    private static func sources(from inputs: [String]) throws -> [SourceInput] {
        var paths: [String] = []
        for input in inputs {
            let path = absolutePath(input)
            guard FileManager.default.fileExists(atPath: path) else {
                throw ToolError("no such file or directory: \(path)")
            }
            let isDirectory = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            if isDirectory == true {
                paths += swiftFiles(under: path)
            } else {
                paths.append(path)
            }
        }
        return try Array(Set(paths)).sorted().map { path in
            guard let data = FileManager.default.contents(atPath: path) else {
                throw ToolError("cannot read \(path)")
            }
            return SourceInput(path: path, text: String(decoding: data, as: UTF8.self))
        }
    }

    /// Paths are built by joining strings, not by asking the file system to
    /// enumerate URLs: the enumerator canonicalizes (`/tmp` becomes
    /// `/private/tmp`), and a path that no longer starts with the directory it
    /// was found under cannot be made relative to a baseline.
    private static func swiftFiles(under directory: String) -> [String] {
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: directory) else { return [] }
        return subpaths
            .filter { $0.hasSuffix(".swift") && !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
            .map { directory + "/" + $0 }
    }

    private static func writeStamp(at path: String, summary: String) throws {
        try FileManager.default.createDirectory(atPath: directory(of: path), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: Data((summary + "\n").utf8)) else {
            throw ToolError("cannot write \(path)")
        }
    }

    /// Absolute with `.` and `..` resolved, but with symlinks left alone: diagnostics
    /// must name files the way the build system does, and baseline paths are
    /// relative to a directory reached the same way.
    private static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }

    private static func directory(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("stoic-lint: \(message)\n").utf8))
        exit(2)
    }
}

private struct ToolError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

#else

import Foundation

/// Without the `Lint` trait the tool does not exist, but SwiftPM still builds
/// every target of a package, so this stub keeps `swift build` working and
/// says how to get the real tool.
@main
enum StoicLintTool {
    static func main() {
        FileHandle.standardError.write(
            Data(
                """
                stoic-lint was built without the Lint trait.
                Depend on Stoic with `traits: ["Lint"]` to build the tool (design/13).

                """.utf8))
        exit(2)
    }
}

#endif
