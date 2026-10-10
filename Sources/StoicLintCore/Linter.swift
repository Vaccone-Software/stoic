#if STOIC_LINT
import SwiftParser
import SwiftSyntax

/// Turns Swift source text into findings.
///
/// Pure on purpose: no file system, no process, no clock. A rule is a
/// function from a string to findings, so every rule is tested from an
/// inline snippet, and the command line is a thin shell around this.
///
/// The linter is syntactic. It sees no types, so it matches the shapes the
/// patterns take in practice (`sem.wait()`, `Task.detached`, `try?` as a
/// statement) and prefers a missed finding to a false one: a finding is a
/// build error, and an error the author cannot trust trains people to
/// suppress without reading.
public struct Linter: Sendable {
    public init() {}

    /// Lints one file's text. `path` is reported as given; it also decides
    /// whether the file counts as test code (see ``isTestPath(_:)``).
    public func lint(source: String, path: String) -> [Finding] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let lines = converter.sourceLines

        let collector = AllowCollector(converter: converter, lines: lines)
        collector.walk(tree)
        let reporter = Reporter(path: path, converter: converter, lines: lines, allows: collector.table)

        for makeRule in Self.rules {
            makeRule(reporter).walk(tree)
        }
        reporter.reportAllowsWithoutReason()

        return reporter.findings.sorted {
            ($0.line, $0.column, $0.rule.rawValue) < ($1.line, $1.column, $1.rule.rawValue)
        }
    }

    /// Whether `path` is test code, where `try!` and friends are routine.
    /// A path component named `Tests`, or a file whose name ends in
    /// `Tests.swift`.
    public static func isTestPath(_ path: String) -> Bool {
        if path.contains("/Tests/") { return true }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix("Tests.swift")
    }

    /// Every rule, as a factory over the shared reporter. One visitor per
    /// rule keeps each rule's state (the async-context stack, say) out of
    /// the others, at the price of one cheap tree walk apiece.
    static let rules: [@Sendable (Reporter) -> RuleVisitor] = [
        { UncheckedSendableRule(reporter: $0) },
        { NonisolatedUnsafeRule(reporter: $0) },
        { TaskDetachedRule(reporter: $0) },
        { SleepForTimeoutRule(reporter: $0) },
        { UnboundedStreamRule(reporter: $0) },
        { BlockingInAsyncRule(reporter: $0) },
    ]
}

/// The base of every rule: a syntax visitor that reports through a shared
/// reporter.
class RuleVisitor: SyntaxVisitor {
    let reporter: Reporter

    init(reporter: Reporter) {
        self.reporter = reporter
        super.init(viewMode: .sourceAccurate)
    }
}

/// Collects findings for one file, applying suppression comments.
final class Reporter {
    let path: String
    let isTestFile: Bool
    private let converter: SourceLocationConverter
    private let lines: [String]
    private let allows: AllowTable
    private(set) var findings: [Finding] = []

    init(path: String, converter: SourceLocationConverter, lines: [String], allows: AllowTable) {
        self.path = path
        self.isTestFile = Linter.isTestPath(path)
        self.converter = converter
        self.lines = lines
        self.allows = allows
    }

    /// Reports `rule` at `node`, unless a justification covers it.
    func report(_ rule: RuleID, at node: some SyntaxProtocol, message: String, fixIt: String? = nil) {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        var anchors = [location.line]
        if let statement = enclosingStatement(of: Syntax(node)) {
            let line = converter.location(for: statement.positionAfterSkippingLeadingTrivia).line
            if line != location.line { anchors.append(line) }
        }
        guard !allows.permits(rule, anchoredAt: anchors) else { return }
        findings.append(
            Finding(
                rule: rule,
                file: path,
                line: location.line,
                column: location.column,
                message: message,
                fixIt: fixIt,
                sourceLine: sourceLine(location.line)
            )
        )
    }

    /// A suppression with no reason suppresses nothing and is reported.
    func reportAllowsWithoutReason() {
        for allow in allows.all where !allow.hasReason {
            let named = allow.rules.isEmpty ? "<rule>" : allow.rules.joined(separator: ", ")
            findings.append(
                Finding(
                    rule: .allowWithoutReason,
                    file: path,
                    line: allow.line,
                    column: allow.column,
                    message:
                        "`stoic:allow(\(named))` gives no reason, so it suppresses nothing. Say why this is safe.",
                    fixIt: "write `// stoic:allow(\(named)): <why this is safe here>`",
                    sourceLine: sourceLine(allow.line)
                )
            )
        }
    }

    private func sourceLine(_ line: Int) -> String {
        lines.indices.contains(line - 1) ? lines[line - 1].trimmingSpaces() : ""
    }

    /// The innermost statement or member declaration holding `node`. A
    /// justification above it covers a finding on any of its lines.
    private func enclosingStatement(of node: Syntax) -> Syntax? {
        var current: Syntax? = node
        while let candidate = current {
            if candidate.is(CodeBlockItemSyntax.self) || candidate.is(MemberBlockItemSyntax.self) {
                return candidate
            }
            current = candidate.parent
        }
        return nil
    }
}

#endif
