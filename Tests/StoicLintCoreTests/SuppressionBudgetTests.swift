#if STOIC_LINT
import Foundation
import StoicLintCore
import StoicTesting
import Testing

/// The escape ratchet: a baseline records the findings `stoic:allow`
/// suppressed, so a new suppression cannot appear without a baseline change.
@Suite("Suppression budget")
struct SuppressionBudgetTests {
    private let root = "/work"
    private let path = "/work/Sources/App/Store.swift"

    /// Two justified escapes and nothing else.
    private let justified = """
        // stoic:allow(unchecked-sendable): every access goes through `lock`
        final class Box: @unchecked Sendable {}
        let pattern = try! load() // stoic:allow(force-try): bundled resource, checked at build time
        """

    private func lint(_ text: String, baseline: Baseline?, path: String? = nil) -> LintOutcome {
        Linter().lint(
            [SourceInput(path: path ?? self.path, text: text)], baseline: baseline, baselineRoot: root,
            baselinePath: "/work/.stoic-lint-baseline.json")
    }

    private func recorded(_ text: String, path: String? = nil) -> Baseline {
        let report = Linter().analyze(source: text, path: path ?? self.path)
        return Baseline(recording: report.findings, suppressed: report.suppressed, relativeTo: root)
    }

    @Test func aFileReportKeepsWhatWasSuppressed() {
        let report = Linter().analyze(source: justified, path: path)
        #expect(report.findings.isEmpty)
        #expect(report.suppressed.map(\.rule) == [.uncheckedSendable, .forceTry])
        #expect(report.suppressed.map(\.line) == [2, 3])
    }

    @Test func aReasonlessAllowSuppressesNothingSoIsNoEscape() {
        let report = Linter().analyze(source: "let x = try! load() // stoic:allow(force-try)\n", path: path)
        #expect(report.suppressed.isEmpty)
        #expect(Set(report.findings.map(\.rule)) == [.forceTry, .allowWithoutReason])
    }

    @Test func withoutABaselineEscapesAreCountedButDoNotFail() {
        let outcome = lint(justified, baseline: nil)
        #expect(outcome.exitCode == 0)
        #expect(outcome.suppressed.count == 2)
        #expect(outcome.summary == "stoic-lint: 0 error(s), 2 suppressed in 1 file(s)")
    }

    @Test func recordedEscapesPass() {
        let outcome = lint(justified, baseline: recorded(justified))
        #expect(outcome.exitCode == 0)
        #expect(outcome.errors.isEmpty)
        #expect(outcome.staleSuppressions.isEmpty)
    }

    @Test(.failureMode("design/13", "a suppression is added after the baseline was written"))
    func aNewEscapeFailsAtTheFindingItSuppresses() throws {
        let later = justified + "\nlet more = try! load() // stoic:allow(force-try): it is fine, honestly\n"
        let outcome = lint(later, baseline: recorded(justified))
        #expect(outcome.exitCode == 1)
        let error = try #require(outcome.errors.first)
        #expect(outcome.errors.count == 1)
        #expect(error.rule == .unrecordedSuppression)
        #expect(error.line == 4)
        #expect(error.column == 12)
        #expect(error.message.contains("stoic:allow(force-try)"))
        #expect(error.fixIt?.contains("--write-baseline") == true)
        #expect(outcome.report().contains("error: [stoic.unrecorded-suppression]"))
    }

    @Test func movingAnEscapeIsANewOneAndAStaleOne() {
        // Same count, different place: the budget is per escape, not a number.
        let moved = """
            // stoic:allow(unchecked-sendable): every access goes through `lock`
            final class Box: @unchecked Sendable {}
            let other = try! decode() // stoic:allow(force-try): written by the step above
            """
        let outcome = lint(moved, baseline: recorded(justified))
        #expect(outcome.errors.map(\.rule) == [.unrecordedSuppression])
        #expect(outcome.staleSuppressions.count == 1)
        #expect(outcome.staleSuppressions.first?.rule == "stoic.force-try")
    }

    @Test(.failureMode("design/13", "a recorded suppression is removed"))
    func removingAnEscapeLeavesAStaleEntryAndPasses() {
        let fixed = """
            // stoic:allow(unchecked-sendable): every access goes through `lock`
            final class Box: @unchecked Sendable {}
            let pattern = try load()
            """
        let outcome = lint(fixed, baseline: recorded(justified))
        #expect(outcome.exitCode == 0)
        #expect(outcome.staleSuppressions.count == 1)
        #expect(outcome.report().contains("1 recorded suppression(s) no longer occur"))
        #expect(outcome.summary.contains("1 stale"))
    }

    @Test(.failureMode("design/13", "the baseline predates suppression records"))
    func aBaselineWithoutSuppressionsEnforcesNoBudget() throws {
        // A version 1 baseline written before suppressions were recorded.
        let legacy = try Baseline.decode(Data(#"{ "entries": [], "version": 1 }"#.utf8))
        #expect(legacy.suppressions == nil)
        let outcome = lint(justified, baseline: legacy)
        #expect(outcome.exitCode == 0)
        #expect(outcome.suppressed.count == 2)
    }

    @Test func anEmptySuppressionListMeansNoEscapesAllowed() {
        let outcome = lint(justified, baseline: Baseline(entries: [], suppressions: []))
        #expect(outcome.errors.map(\.rule) == [.unrecordedSuppression, .unrecordedSuppression])
    }

    @Test func escapesInFilesOutsideTheRunAreNotStale() {
        let baseline = recorded(justified, path: "/work/Sources/Other/Elsewhere.swift")
        let outcome = lint("let x = 1\n", baseline: baseline)
        #expect(outcome.exitCode == 0)
        #expect(outcome.staleSuppressions.isEmpty)
    }

    @Test func theRatchetCannotBeAllowedAway() {
        // The error is decided across the run, after every comment was read.
        let later =
            justified + "\n// stoic:allow(unrecorded-suppression): please\nlet more = try! load() // stoic:allow(force-try): fine\n"
        let outcome = lint(later, baseline: recorded(justified))
        #expect(outcome.errors.map(\.rule).contains(.unrecordedSuppression))
    }

    @Test func aFindingAndAnEscapeOnOneLineAreTrackedApart() {
        // The baselined finding stays a warning; the escape is its own entry.
        let source = "let x = try! load() // stoic:allow(force-try): bundled\nfunc f() {\n    try? save()\n}\n"
        let outcome = lint(source, baseline: recorded(source))
        #expect(outcome.exitCode == 0)
        #expect(outcome.accepted.map(\.rule) == [.discardedTry])
        #expect(outcome.suppressed.map(\.rule) == [.forceTry])
    }

    @Test func aFindingOnALastLineWithoutANewlineKeepsItsIdentity() {
        // Appending a line after it gives it a newline; that is not a change.
        let before = "func f() {}\nlet x = try! load()"
        let after = before + "\nlet y = 1\n"
        let baseline = recorded(before)
        let outcome = lint(after, baseline: baseline)
        #expect(outcome.errors.isEmpty)
        #expect(outcome.accepted.map(\.rule) == [.forceTry])
        #expect(outcome.stale.isEmpty)
    }

    @Test func suppressionsRoundTripAsStableJSON() throws {
        let baseline = recorded(justified)
        let data = try baseline.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""suppressions""#))
        #expect(text.contains(#""file" : "Sources/App/Store.swift""#))
        #expect(try Baseline.decode(data) == baseline)
        #expect(try baseline.jsonData() == data, "the bytes are stable, so a baseline diffs cleanly")
    }

    @Test func aBaselineWithNoSuppressionListWritesNone() throws {
        let text = String(decoding: try Baseline(entries: []).jsonData(), as: UTF8.self)
        #expect(!text.contains("suppressions"))
    }
}
#endif
