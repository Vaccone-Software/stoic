#if STOIC_LINT
import Foundation
import StoicLintCore
import Testing

/// Properties every rule must have, checked over all of them, so a new rule
/// cannot ship without an example, a suggestion, a working suppression and
/// its row in design/13.
@Suite("Every rule")
struct RuleCatalogTests {
    /// The smallest snippet that earns each rule, and nothing else. A rule
    /// added to `RuleID` without one here fails ``everyRuleHasAnExample()``.
    static let examples: [RuleID: String] = [
        .blockingInAsync: "func f() async {\n    semaphore.wait()\n}\n",
        .uncheckedSendable: "final class Box: @unchecked Sendable {}\n",
        .nonisolatedUnsafe: "nonisolated(unsafe) var shared = 0\n",
        .unboundedStream: "let stream = AsyncStream<Int> { _ in }\n",
        .discardedTry: "func f() {\n    try? save()\n}\n",
        .forceTry: "let value = try! load()\n",
        .taskDetached: "let task = Task.detached {}\n",
        .sleepForTimeout: "func f() {\n    queue.asyncAfter(deadline: .now() + 1) {}\n}\n",
        .preconcurrency: "@preconcurrency import Legacy\n",
        .swallowedCancellation:
            "func f() async {\n    while true {\n        do { try await work() } catch is CancellationError {}\n    }\n}\n",
        .swallowedError: "func f() {\n    do { try save() } catch {}\n}\n",
        .bareTaskSleep: "func f() async throws {\n    try await Task.sleep(for: .seconds(1))\n}\n",
        .keyInsideRetry:
            "func f() async throws {\n    try await retry(schedule) { _ in try await send(IdempotencyKey.random()) }\n}\n",
        .handRolledRetry:
            "func f() async throws {\n    for _ in 1...3 {\n        do { return try await fetch() } catch { try await clock.sleep(for: .seconds(1)) }\n    }\n}\n",
        .keepAliveLoop:
            "func f() async throws {\n    while true {\n        do { try await run() } catch { try await clock.sleep(for: .seconds(1)) }\n    }\n}\n",
        .unboundedTaskGroup:
            "func f() async {\n    await withTaskGroup(of: Void.self) { group in\n        for url in urls { group.addTask { await fetch(url) } }\n    }\n}\n",
        .unsafeContinuation: "func f() async {\n    await withUnsafeContinuation { $0.resume() }\n}\n",
        .allowWithoutReason: "// stoic:allow(force-try)\nlet x = 1\n",
    ]

    /// Rules a single file can earn. `unrecorded-suppression` is decided
    /// across a run against a baseline, and is tested in
    /// `SuppressionBudgetTests`.
    static let sourceRules = RuleID.allCases.filter { $0 != .unrecordedSuppression }

    static let designDocument = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "design/13-build-enforcement.md")

    @Test func everyRuleHasAnExample() {
        #expect(Set(Self.examples.keys) == Set(Self.sourceRules))
    }

    @Test(arguments: Self.sourceRules)
    func theExampleEarnsExactlyThatRule(_ rule: RuleID) throws {
        let source = try #require(Self.examples[rule])
        #expect(findings(in: source).map(\.rule) == [rule])
    }

    @Test(arguments: Self.sourceRules.filter { $0 != .allowWithoutReason })
    func everyFindingNamesItsReplacement(_ rule: RuleID) throws {
        let source = try #require(Self.examples[rule])
        let finding = try #require(findings(in: source).first)
        #expect(!finding.message.isEmpty)
        #expect(finding.message.hasSuffix("."), "a message is a sentence")
        let fixIt = try #require(finding.fixIt, "every rule says what to write instead")
        #expect(!fixIt.isEmpty)
        #expect(!finding.sourceLine.isEmpty, "the source line is the finding's baseline identity")
    }

    @Test(arguments: Self.sourceRules.filter { $0 != .allowWithoutReason })
    func everyRuleCanBeJustifiedAboveTheStatement(_ rule: RuleID) throws {
        let source = try #require(Self.examples[rule])
        let finding = try #require(findings(in: source).first)
        // Put the justification alone on the line above the finding.
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indent = String(lines[finding.line - 1].prefix { $0 == " " })
        lines.insert("\(indent)// stoic:allow(\(rule.shortName)): the catalog test says so", at: finding.line - 1)
        #expect(findings(in: lines.joined(separator: "\n")).isEmpty)
    }

    @Test(arguments: Self.sourceRules.filter { $0 != .allowWithoutReason })
    func aJustificationForAnotherRuleDoesNotCover(_ rule: RuleID) throws {
        let source = try #require(Self.examples[rule])
        let other = rule == .forceTry ? RuleID.discardedTry : .forceTry
        let justified = "// stoic:allow(\(other.shortName)): not this one\n" + source
        #expect(findings(in: justified).map(\.rule) == [rule])
    }

    @Test func aReasonlessAllowIsNeverItselfSuppressible() {
        let source = "// stoic:allow(allow-without-reason): trying anyway\n// stoic:allow(force-try)\nlet x = 1\n"
        #expect(findings(in: source).map(\.rule) == [.allowWithoutReason])
    }

    @Test(arguments: RuleID.allCases)
    func everyRuleHasARowInTheContract(_ rule: RuleID) throws {
        let text = try String(contentsOf: Self.designDocument, encoding: .utf8)
        let row = text.split(separator: "\n").first { $0.hasPrefix("| `\(rule.rawValue)`") }
        #expect(row != nil, "design/13's rule table has no row for \(rule.rawValue)")
    }

    @Test func theContractListsNoRuleThatDoesNotExist() throws {
        let text = try String(contentsOf: Self.designDocument, encoding: .utf8)
        let listed = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("| `stoic.") else { return nil }
            return line.dropFirst(3).prefix { $0 != "`" }.description
        }
        #expect(Set(listed) == Set(RuleID.allCases.map(\.rawValue)))
    }

    @Test(arguments: RuleID.allCases)
    func bothSpellingsOfTheNameResolve(_ rule: RuleID) {
        #expect(RuleID(named: rule.rawValue) == rule)
        #expect(RuleID(named: rule.shortName) == rule)
        #expect(RuleID(named: " \(rule.shortName) ") == rule)
    }

    @Test(arguments: Self.sourceRules)
    func theExampleIsLintedTheSameWayTwice(_ rule: RuleID) throws {
        // Rules carry state across a walk (scope stacks); a fresh linter per
        // file must give the same answer every time.
        let source = try #require(Self.examples[rule])
        #expect(findings(in: source) == findings(in: source))
    }
}
#endif
