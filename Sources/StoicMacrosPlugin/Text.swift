#if STOIC_MACROS
import SwiftSyntax

/// A Swift string literal holding `text`.
func swiftLiteral(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

/// The documentation comment before a declaration, as one string.
///
/// Lines of one paragraph are joined with a space, a blank `///` line starts
/// a new paragraph, and the comment markers are gone. That is what the JSON
/// Schema export's `description` and a settings screen's help text want;
/// nobody wants a newline in the middle of a sentence because the source
/// was wrapped at 80 columns.
func documentation(of node: some SyntaxProtocol) -> String? {
    var lines: [String] = []
    for piece in node.leadingTrivia {
        switch piece {
        case .docLineComment(let text):
            var line = text.dropFirst(3)
            if line.first == " " { line = line.dropFirst() }
            lines.append(String(line))
        case .docBlockComment(let text):
            var body = text.dropFirst(3)
            if body.hasSuffix("*/") { body = body.dropLast(2) }
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                var trimmed = line.drop { $0 == " " || $0 == "\t" }
                if trimmed.first == "*" { trimmed = trimmed.dropFirst() }
                lines.append(String(trimmed.drop { $0 == " " }))
            }
        default:
            // A blank line or a plain comment between the documentation and
            // the declaration detaches it, as Swift's own tools see it.
            if case .newlines(let count) = piece, count > 1 { lines.removeAll() }
            if case .lineComment = piece { lines.removeAll() }
        }
    }
    var paragraphs: [String] = []
    var current: [String] = []
    for line in lines {
        let trimmed = line.trimmingSpaces()
        if trimmed.isEmpty {
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            current = []
        } else {
            current.append(trimmed)
        }
    }
    if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
    let text = paragraphs.joined(separator: "\n\n")
    return text.isEmpty ? nil : text
}

extension String {
    func trimmingSpaces() -> String {
        var scalars = Substring(self)
        while let first = scalars.first, first == " " || first == "\t" { scalars = scalars.dropFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars = scalars.dropLast() }
        return String(scalars)
    }

    var lowercasingFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
#endif
