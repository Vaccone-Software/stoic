#if STOIC_LINT
import Foundation
import StoicLintCore
import Testing

@Suite("Diagnostic format")
struct DiagnosticFormatTests {
    /// The format is a contract with Xcode and SwiftPM, which parse it out
    /// of tool output. Changing it silently turns errors into log noise.
    @Test func goldenOutput() {
        let source = """
            import Foundation

            func load() async {
                semaphore.wait()
                let data = try! read()
            }
            """
        let outcome = Linter().lint([SourceInput(path: "/work/Sources/App/Loader.swift", text: source)])
        #expect(
            outcome.report() == """
                /work/Sources/App/Loader.swift:4:5: error: [stoic.blocking-in-async] `wait()` parks a thread of the cooperative pool inside async code; under load that starves or deadlocks the pool.
                /work/Sources/App/Loader.swift:4:5: note: use `AsyncSemaphore` / `AsyncMutex`, or `await` the work directly
                /work/Sources/App/Loader.swift:5:16: error: [stoic.force-try] `try!` crashes the process on any error, with no context about what failed.
                /work/Sources/App/Loader.swift:5:16: note: propagate with `try`, or handle the error; if it truly cannot fail, say why with `// stoic:allow(force-try): <why>`
                stoic-lint: 2 error(s) in 1 file(s)

                """)
        #expect(outcome.exitCode == 1)
    }

    @Test func aCleanRunSaysSoAndExitsZero() {
        let outcome = Linter().lint([SourceInput(path: "/work/A.swift", text: "let x = 1\n")])
        #expect(outcome.report() == "stoic-lint: 0 error(s) in 1 file(s)\n")
        #expect(outcome.exitCode == 0)
    }

    @Test func columnsAreUTF8Bytes() throws {
        // "é" is two bytes; Xcode counts bytes.
        let found = Linter().lint(source: "let é = 1; Task.detached { }\n", path: "/work/A.swift")
        let first = try #require(found.first)
        #expect(first.column == 13)
    }
}

@Suite("Baseline")
struct BaselineTests {
    private let root = "/work"
    private let source = """
        func a() {
            try? save()
        }
        func b() {
            Task.detached { }
        }
        """

    private func lint(_ text: String, baseline: Baseline? = nil, path: String = "/work/Sources/A.swift") -> LintOutcome {
        Linter().lint(
            [SourceInput(path: path, text: text)], baseline: baseline, baselineRoot: root,
            baselinePath: "/work/.stoic-lint-baseline.json")
    }

    private func recorded() -> Baseline {
        let findings = Linter().lint(source: source, path: "/work/Sources/A.swift")
        return Baseline(recording: findings, relativeTo: root)
    }

    @Test func roundTripsThroughJSON() throws {
        let baseline = recorded()
        #expect(baseline.entries.count == 2)
        let data = try baseline.jsonData()
        #expect(try Baseline.decode(data) == baseline)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"file\" : \"Sources/A.swift\""))
        #expect(text.contains("\"rule\" : \"stoic.discarded-try\""))
        #expect(text.hasSuffix("\n"))
    }

    @Test func theJSONIsStableAcrossRuns() throws {
        #expect(try recorded().jsonData() == recorded().jsonData())
    }

    @Test func baselinedFindingsAreWarningsAndDoNotFail() {
        let outcome = lint(source, baseline: recorded())
        #expect(outcome.errors.isEmpty)
        #expect(outcome.accepted.count == 2)
        #expect(outcome.exitCode == 0)
        let report = outcome.report()
        #expect(report.contains("/work/Sources/A.swift:2:5: warning: [stoic.discarded-try]"))
        #expect(report.contains("/work/Sources/A.swift:5:5: warning: [stoic.task-detached]"))
        #expect(!report.contains(": error:"))
        #expect(report.hasSuffix("stoic-lint: 0 error(s), 2 baselined in 1 file(s)\n"))
    }

    @Test func aNewFindingFailsEvenWithABaseline() {
        let changed = source + "\nfunc c() {\n    try? other()\n}\n"
        let outcome = lint(changed, baseline: recorded())
        #expect(outcome.errors.map(\.rule) == [.discardedTry])
        #expect(outcome.errors.first?.line == 8)
        #expect(outcome.accepted.count == 2)
        #expect(outcome.exitCode == 1)
    }

    @Test func entriesSurviveEditsElsewhereInTheFile() {
        // Lines move; the hash is of the line's text, so nothing changes.
        let shifted = "// a new header comment\n// and another\n\n" + source
        let outcome = lint(shifted, baseline: recorded())
        #expect(outcome.errors.isEmpty)
        #expect(outcome.accepted.map(\.line) == [5, 8])
    }

    @Test func indentationChangesDoNotMatter() {
        let reindented = source.replacingOccurrences(of: "    try?", with: "\t\ttry?")
        #expect(lint(reindented, baseline: recorded()).errors.isEmpty)
    }

    @Test func changingTheOffendingLineIsANewFinding() {
        let edited = source.replacingOccurrences(of: "try? save()", with: "try? save(force: true)")
        let outcome = lint(edited, baseline: recorded())
        #expect(outcome.errors.map(\.rule) == [.discardedTry])
        #expect(outcome.stale.count == 1)
    }

    @Test func fixingAFindingLeavesAStaleEntryAndAWarning() {
        let fixed = source.replacingOccurrences(of: "    try? save()\n", with: "    try save()\n")
        let outcome = lint(fixed, baseline: recorded())
        #expect(outcome.errors.isEmpty)
        #expect(outcome.stale.count == 1)
        #expect(outcome.stale.first?.rule == "stoic.discarded-try")
        #expect(outcome.report().contains("/work/.stoic-lint-baseline.json:1:1: warning: [stoic.baseline] 1 accepted"))
        #expect(outcome.exitCode == 0)
    }

    @Test func theCountMayOnlyFall() {
        // A baselined line copied a second time is a new finding: each entry
        // accepts one.
        let doubled = "func a() {\n    try? save()\n    try? save()\n}\n"
        let baseline = Baseline(
            recording: Linter().lint(source: "func a() {\n    try? save()\n}\n", path: "/work/Sources/A.swift"),
            relativeTo: root)
        let outcome = lint(doubled, baseline: baseline)
        #expect(outcome.accepted.count == 1)
        #expect(outcome.errors.count == 1)
    }

    @Test func entriesForFilesOutsideTheRunAreNotStale() {
        let other = Baseline(entries: [
            .init(file: "Sources/Elsewhere.swift", rule: "stoic.force-try", hash: Baseline.hash(ofLine: "try! x()"))
        ])
        #expect(lint("let x = 1\n", baseline: other).stale.isEmpty)
    }

    @Test func pathsOutsideTheRootStayAbsolute() {
        #expect(Baseline.relativePath("/work/Sources/A.swift", to: "/work") == "Sources/A.swift")
        #expect(Baseline.relativePath("/work/Sources/A.swift", to: "/work/") == "Sources/A.swift")
        #expect(Baseline.relativePath("/other/A.swift", to: "/work") == "/other/A.swift")
        #expect(Baseline.relativePath("/workshop/A.swift", to: "/work") == "/workshop/A.swift")
    }

    @Test func theHashIsStableAndTrimmed() {
        #expect(Baseline.hash(ofLine: "try? save()") == Baseline.hash(ofLine: "    try? save()  "))
        #expect(Baseline.hash(ofLine: "try? save()") != Baseline.hash(ofLine: "try? load()"))
        // FNV-1a of "" is its offset basis: pins the algorithm so a baseline written today stays readable.
        #expect(Baseline.hash(ofLine: "") == "cbf29ce484222325")
        #expect(Baseline.hash(ofLine: "a") == "af63dc4c8601ec8c")
    }

    @Test func anUnknownVersionIsRejected() {
        let data = Data(#"{"version": 2, "entries": []}"#.utf8)
        #expect(throws: BaselineError.unsupportedVersion(2)) { try Baseline.decode(data) }
    }
}

@Suite("Command line")
struct InvocationTests {
    @Test func parsesTheLintForm() throws {
        let invocation = try Invocation.parse(["--baseline", "b.json", "--output=stamp", "A.swift", "B.swift"])
        #expect(invocation.mode == .lint)
        #expect(invocation.baselinePath == "b.json")
        #expect(invocation.outputPath == "stamp")
        #expect(invocation.inputs == ["A.swift", "B.swift"])
    }

    @Test func parsesWriteBaseline() throws {
        let invocation = try Invocation.parse(["--write-baseline", "b.json", "Sources"])
        #expect(invocation.mode == .writeBaseline("b.json"))
        #expect(invocation.inputs == ["Sources"])
    }

    @Test func doubleDashEndsOptions() throws {
        #expect(try Invocation.parse(["--", "-odd.swift"]).inputs == ["-odd.swift"])
    }

    @Test func rejectsBadUsage() {
        #expect(throws: Invocation.UsageError.self) { try Invocation.parse([]) }
        #expect(throws: Invocation.UsageError.self) { try Invocation.parse(["--bogus", "A.swift"]) }
        #expect(throws: Invocation.UsageError.self) { try Invocation.parse(["A.swift", "--baseline"]) }
        #expect(throws: Invocation.UsageError.self) {
            try Invocation.parse(["--write-baseline", "b", "--baseline", "c", "A.swift"])
        }
    }

    @Test func helpNeedsNoPaths() throws {
        #expect(try Invocation.parse(["--help"]).mode == .help)
    }
}
#endif
