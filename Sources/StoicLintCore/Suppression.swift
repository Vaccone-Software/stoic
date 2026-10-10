#if STOIC_LINT
import SwiftSyntax

/// A `// stoic:allow(<rule>): <reason>` comment.
///
/// Every escape hatch in Stoic's rules is the same one: say which rule you
/// are stepping around and why. The reason is not decoration. A comment
/// without one does not suppress anything and is itself a finding
/// (`stoic.allow-without-reason`), so "allow" can never be typed as a reflex.
struct Allow {
    /// Rule names with the `stoic.` prefix dropped, as written.
    var rules: [String]
    var reason: String?
    var line: Int
    var column: Int
    /// True when the comment is alone on its line, which is what lets it
    /// speak for the line below. A trailing comment speaks for its own line
    /// only; otherwise it would silently cover whatever happens to follow.
    var standalone: Bool

    var hasReason: Bool { reason != nil }

    func covers(_ rule: RuleID) -> Bool {
        hasReason && rules.contains(rule.shortName)
    }

    /// Parses the text of one comment. Returns nil when it is not an allow
    /// comment at all. Only a comment that _starts_ with the marker counts,
    /// so documentation that mentions the syntax is left alone.
    init?(commentText: String, line: Int, column: Int, standalone: Bool) {
        var text = Substring(commentText)
        while let first = text.first, first == "/" || first == "*" || first == "!" { text = text.dropFirst() }
        var body = String(text).trimmingSpaces()
        if body.hasSuffix("*/") { body = String(body.dropLast(2)).trimmingSpaces() }
        let marker = "stoic:allow("
        guard body.hasPrefix(marker) else { return nil }
        let afterMarker = body.dropFirst(marker.count)

        self.line = line
        self.column = column
        self.standalone = standalone
        guard let close = afterMarker.firstIndex(of: ")") else {
            // `stoic:allow(` with no closing parenthesis: no rule, no reason.
            self.rules = []
            self.reason = nil
            return
        }
        let names = afterMarker[..<close].split(separator: ",").map {
            let name = String($0).trimmingSpaces()
            return name.hasPrefix(RuleID.prefix) ? String(name.dropFirst(RuleID.prefix.count)) : name
        }
        self.rules = names.filter { !$0.isEmpty }
        let rest = afterMarker[afterMarker.index(after: close)...]
        let trimmed = String(rest).trimmingSpaces()
        if trimmed.hasPrefix(":") {
            let reason = String(trimmed.dropFirst()).trimmingSpaces()
            self.reason = reason.isEmpty ? nil : reason
        } else {
            self.reason = nil
        }
    }
}

/// Every allow comment in a file, indexed by line.
struct AllowTable {
    private(set) var all: [Allow] = []
    private var byLine: [Int: [Allow]] = [:]

    mutating func add(_ allow: Allow) {
        all.append(allow)
        byLine[allow.line, default: []].append(allow)
    }

    /// Whether a finding of `rule` is justified, given the lines it is
    /// anchored to: the line it sits on, and the line its statement or
    /// declaration starts on (a justification written above a declaration
    /// should cover a clause three lines down it). On each such line a
    /// comment counts when it shares the line or stands alone on the line
    /// above.
    func permits(_ rule: RuleID, anchoredAt lines: [Int]) -> Bool {
        guard rule != .allowWithoutReason else { return false }
        for line in lines {
            if byLine[line, default: []].contains(where: { $0.covers(rule) }) { return true }
            if byLine[line - 1, default: []].contains(where: { $0.standalone && $0.covers(rule) }) { return true }
        }
        return false
    }
}

/// Finds the allow comments in a syntax tree by walking its trivia, so a
/// string literal that happens to contain the marker is not mistaken for one.
final class AllowCollector: SyntaxVisitor {
    private let converter: SourceLocationConverter
    private let lines: [String]
    private(set) var table = AllowTable()

    init(converter: SourceLocationConverter, lines: [String]) {
        self.converter = converter
        self.lines = lines
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        scan(token.leadingTrivia, from: token.position)
        scan(token.trailingTrivia, from: token.endPositionBeforeTrailingTrivia)
        return .skipChildren
    }

    private func scan(_ trivia: Trivia, from start: AbsolutePosition) {
        var position = start
        for piece in trivia {
            switch piece {
            case .lineComment(let text), .blockComment(let text), .docLineComment(let text), .docBlockComment(let text):
                let location = converter.location(for: position)
                let standalone = isStandalone(line: location.line)
                if let allow = Allow(
                    commentText: text, line: location.line, column: location.column, standalone: standalone
                ) {
                    table.add(allow)
                }
            default:
                break
            }
            position += piece.sourceLength
        }
    }

    private func isStandalone(line: Int) -> Bool {
        guard lines.indices.contains(line - 1) else { return false }
        let text = lines[line - 1].trimmingSpaces()
        return text.hasPrefix("//") || text.hasPrefix("/*")
    }
}

#endif
