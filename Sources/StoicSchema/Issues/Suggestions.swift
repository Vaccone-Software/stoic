/// "Did you mean": the nearest names to a misspelt one.
///
/// The same machinery serves object keys, enumeration values and (later)
/// union tags, so a typo gets the same quality of help wherever it is made.
enum Suggestions {
    /// The most suggestions an issue carries. More than three stops being
    /// help and starts being a list to read.
    static let limit = 3

    /// Spellings are compared in a normal form that ignores what people
    /// get wrong without meaning to: case, and the `_`, `-` and space that
    /// separate words in snake_case, kebab-case and "Title Case" but not in
    /// camelCase. `scroll_speed`, `ScrollSpeed` and `scrollspeed` are one
    /// word as far as a typo is concerned.
    static func normalized(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "_", "-", " ": continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out.lowercased()
    }

    /// The largest distance that still counts as a typo for an input of
    /// `length` characters: one edit from three characters up, two from six.
    /// A shorter input has no neighbours worth guessing; with so few
    /// letters nearly everything is one edit from nearly everything.
    static func threshold(forLength length: Int) -> Int {
        min(2, length / 3)
    }

    /// Candidates within the typo threshold of `input`, nearest first, ties
    /// in the order the candidates were given (declaration order, so the
    /// result is the same on every run), at most ``limit``, without
    /// duplicates.
    ///
    /// An input that differs from a candidate only in case or word
    /// separators is at distance zero and so comes first.
    static func nearest(to input: String, among candidates: [String]) -> [String] {
        let wanted = Array(normalized(input).unicodeScalars)
        // A hostile key can be a megabyte long; nobody typed that by mistake.
        guard wanted.count <= 128 else { return [] }
        let allowed = threshold(forLength: wanted.count)
        var scored: [(distance: Int, order: Int, name: String)] = []
        var seen: Set<String> = []
        for (order, name) in candidates.enumerated() {
            let other = Array(normalized(name).unicodeScalars)
            guard abs(other.count - wanted.count) <= allowed else { continue }
            let distance = damerauLevenshtein(wanted, other)
            guard distance <= allowed, seen.insert(name).inserted else { continue }
            scored.append((distance, order, name))
        }
        scored.sort { ($0.distance, $0.order) < ($1.distance, $1.order) }
        return scored.prefix(limit).map(\.name)
    }

    /// Damerau–Levenshtein distance: the fewest insertions, deletions,
    /// substitutions and swaps of two neighbouring characters that turn `a`
    /// into `b`. This is the unrestricted form (Lowrance and Wagner), so
    /// `ca` to `abc` costs 2, not 3 as in the "optimal string alignment"
    /// shortcut. Swaps matter because transposition (`teh`) is the most
    /// common typing error there is.
    static func damerauLevenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        let n = a.count
        let m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        let infinity = n + m
        var lastRow: [Unicode.Scalar: Int] = [:]
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 2), count: n + 2)
        d[0][0] = infinity
        for i in 0...n {
            d[i + 1][0] = infinity
            d[i + 1][1] = i
        }
        for j in 0...m {
            d[0][j + 1] = infinity
            d[1][j + 1] = j
        }
        for i in 1...n {
            var lastMatchingColumn = 0
            for j in 1...m {
                let k = lastRow[b[j - 1]] ?? 0
                let l = lastMatchingColumn
                var cost = 1
                if a[i - 1] == b[j - 1] {
                    cost = 0
                    lastMatchingColumn = j
                }
                d[i + 1][j + 1] = min(
                    d[i][j] + cost,
                    d[i + 1][j] + 1,
                    d[i][j + 1] + 1,
                    d[k][l] + (i - k - 1) + 1 + (j - l - 1)
                )
            }
            lastRow[a[i - 1]] = i
        }
        return d[n + 1][m + 1]
    }
}
