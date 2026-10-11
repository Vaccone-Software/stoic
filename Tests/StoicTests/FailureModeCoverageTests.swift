import Foundation
import Testing

/// Every row of every failure-mode table in `design/` must be proved by a
/// test marked `.failureMode(document, row)`. Rows not yet covered are
/// listed in `design/failure-modes.baseline`, which may only shrink.
///
/// A failure-mode table is either any table under a "## Failure modes"
/// heading, or, wherever it sits, any table whose header row opens with
/// "What happens if" (design/15 keeps its tables under "## As built").
@Suite("Failure-mode coverage")
struct FailureModeCoverageTests {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `design/NN` → the first column of each row of its failure-mode tables.
    static func rows() throws -> Set<String> {
        var rows: Set<String> = []
        let design = root.appending(path: "design")
        for file in try FileManager.default.contentsOfDirectory(atPath: design.path()) where file.hasSuffix(".md") {
            let document = "design/" + file.prefix(2)
            let text = try String(contentsOf: design.appending(path: file), encoding: .utf8)
            var inSection = false
            var inTable = false
            var isFailureTable = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("## ") { inSection = line.hasPrefix("## Failure modes") }
                guard line.hasPrefix("|") else { inTable = false; continue }
                let cell = normalized(line.split(separator: "|", omittingEmptySubsequences: false)[1])
                let isHeader = cell.lowercased().hasPrefix("what happens if")
                // The first line of a table is its header row.
                if !inTable { inTable = true; isFailureTable = isHeader }
                guard inSection || isFailureTable, !line.hasPrefix("| -"), !isHeader, !cell.isEmpty else { continue }
                rows.insert("\(document) | \(cell)")
            }
        }
        return rows
    }

    /// Every `.failureMode("…", "…")` written in a test.
    static func claimed() throws -> Set<String> {
        let pattern = try Regex(#"\.failureMode\(\s*"([^"]+)"\s*,\s*"((?:[^"\\]|\\.)+)"\s*\)"#)
        var claimed: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: root.appending(path: "Tests"), includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift", file.lastPathComponent != "FailureModeCoverageTests.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: pattern) {
                guard let document = match.output[1].substring, let row = match.output[2].substring else { continue }
                claimed.insert("\(document) | \(normalized(row.replacing("\\\"", with: "\"")))")
            }
        }
        return claimed
    }

    static func baseline() throws -> Set<String> {
        let text = try String(contentsOf: root.appending(path: "design/failure-modes.baseline"), encoding: .utf8)
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty })
    }

    static func normalized(_ cell: some StringProtocol) -> String {
        String(cell).replacing("`", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func everyRowIsProvedOrListedInTheBaseline() throws {
        let rows = try Self.rows()
        let claimed = try Self.claimed()
        let baseline = try Self.baseline()
        if ProcessInfo.processInfo.environment["STOIC_WRITE_FAILURE_BASELINE"] == "1" {
            let uncovered = rows.subtracting(claimed).sorted()
            let header = "# Failure-mode rows not yet proved by a test marked .failureMode(document, row).\n# This list may only shrink: FailureModeCoverageTests fails when a row here gains a test.\n"
            try (header + uncovered.joined(separator: "\n") + "\n")
                .write(to: Self.root.appending(path: "design/failure-modes.baseline"), atomically: true, encoding: .utf8)
            return
        }
        let unproved = rows.subtracting(claimed).subtracting(baseline)
        #expect(unproved.isEmpty, "rows with no test and not in the baseline:\n\(unproved.sorted().joined(separator: "\n"))")
        let nowProved = baseline.intersection(claimed)
        #expect(nowProved.isEmpty, "remove from design/failure-modes.baseline, now proved:\n\(nowProved.sorted().joined(separator: "\n"))")
        let gone = baseline.subtracting(rows)
        #expect(gone.isEmpty, "baseline rows that no table has any more:\n\(gone.sorted().joined(separator: "\n"))")
    }

    @Test func everyClaimNamesARowThatExists() throws {
        let stale = try Self.claimed().subtracting(Self.rows())
        #expect(stale.isEmpty, "tests claim rows no table has (rewritten or misspelt):\n\(stale.sorted().joined(separator: "\n"))")
    }
}
