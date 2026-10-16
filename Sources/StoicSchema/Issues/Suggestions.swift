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
    ///
    /// Case is folded in ASCII only. Unicode's case mapping makes keys that
    /// no ASCII reader would match into ASCII ones (the Kelvin sign `K`
    /// lower-cases to `k`), and the same normal form decides which input keys
    /// an object reads as its own, where that would be a parser differential.
    static func normalized(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "_", "-", " ": continue
            case "A"..."Z": out.append(Unicode.Scalar(UInt8(truncatingIfNeeded: scalar.value) | 0x20))
            default: out.append(scalar)
            }
        }
        return String(out)
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
    /// separators is at distance zero and so comes first. A schema that asks
    /// more than once builds a ``SuggestionIndex`` instead, so its names are
    /// normalised once.
    static func nearest(to input: String, among candidates: [String]) -> [String] {
        SuggestionIndex(candidates).nearest(to: input)
    }

    /// Damerau–Levenshtein distance: the fewest insertions, deletions,
    /// substitutions and swaps of two neighbouring characters that turn `a`
    /// into `b`. This is the unrestricted form (Lowrance and Wagner), so
    /// `ca` to `abc` costs 2, not 3 as in the "optimal string alignment"
    /// shortcut. Swaps matter because transposition (`teh`) is the most
    /// common typing error there is.
    static func damerauLevenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        // Within n + m every distance is found, so this is the exact one.
        distance(a, b, within: a.count + b.count) ?? a.count + b.count
    }

    /// A lower bound on ``damerauLevenshtein(_:_:)`` from the letters alone:
    /// of the scalars one side has and the other lacks (counted with
    /// repetition), the larger count. Every edit changes it by at most one
    /// and a swap not at all, and on sorted scalars it is one merge, so most
    /// candidates are ruled out without a table.
    static func bagDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        var (i, j, onlyA, onlyB) = (0, 0, 0, 0)
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
            } else if a[i] < b[j] {
                onlyA += 1
                i += 1
            } else {
                onlyB += 1
                j += 1
            }
        }
        return max(onlyA + a.count - i, onlyB + b.count - j)
    }

    /// ``damerauLevenshtein(_:_:)`` when it is at most `limit`, else `nil`.
    ///
    /// Only distances up to the typo threshold (two) matter, so the table is
    /// filled in a band of `limit` cells either side of the diagonal (a cell
    /// further out is more than `limit` edits away by itself) and every cell
    /// saturates at `limit + 1`. Saturating is exact for the answer: each
    /// step only adds, so a cell that would exceed the cap cannot lead back
    /// under it. The same bound limits how far back a swap can reach: one
    /// from more than `limit + 1` rows or columns away costs more than
    /// `limit` by its own deletions and insertions, so only that far back is
    /// searched. A pair costs O(length × limit), not O(length²).
    static func distance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], within limit: Int) -> Int? {
        let n = a.count
        let m = b.count
        guard abs(n - m) <= limit else { return nil }
        if n == 0 || m == 0 { return max(n, m) }
        let cap = limit + 1
        let width = m + 2
        var d = [Int](repeating: cap, count: (n + 2) * width)
        for i in 0...n { d[(i + 1) * width + 1] = min(i, cap) }
        for j in 0...m { d[width + j + 1] = min(j, cap) }
        for i in 1...n {
            var lastMatchingColumn = 0
            let low = max(1, i - limit)
            let high = min(m, i + limit)
            for j in max(1, low - limit - 1)...high {
                let matches = a[i - 1] == b[j - 1]
                if j >= low {
                    // The last earlier row whose letter is this column's.
                    var k = 0
                    var row = i - 1
                    while row >= max(1, i - limit - 1) {
                        if a[row - 1] == b[j - 1] {
                            k = row
                            break
                        }
                        row -= 1
                    }
                    let l = lastMatchingColumn
                    let value = min(
                        d[i * width + j] + (matches ? 0 : 1),
                        d[(i + 1) * width + j] + 1,
                        d[i * width + j + 1] + 1,
                        d[k * width + l] + (i - k - 1) + 1 + (j - l - 1)
                    )
                    d[(i + 1) * width + j + 1] = min(value, cap)
                }
                if matches { lastMatchingColumn = j }
            }
        }
        let result = d[(n + 1) * width + m + 1]
        return result <= limit ? result : nil
    }
}

/// Names to suggest from, normalised once.
///
/// A schema knows its keys, cases and tags when it is built, so it builds
/// this then, and a document with a thousand misspellings does not normalise
/// the same names a thousand times.
struct SuggestionIndex: Sendable {
    private let names: [String]
    private let spellings: [[Unicode.Scalar]]
    /// Each spelling's scalars in order, for ``Suggestions/bagDistance(_:_:)``.
    private let letters: [[Unicode.Scalar]]

    init(_ names: [String]) {
        self.names = names
        spellings = names.map { Array(Suggestions.normalized($0).unicodeScalars) }
        letters = spellings.map { $0.sorted() }
    }

    /// See ``Suggestions/nearest(to:among:)``.
    func nearest(to input: String) -> [String] {
        let wanted = Array(Suggestions.normalized(input).unicodeScalars)
        // A hostile key can be a megabyte long; nobody typed that by mistake.
        guard wanted.count <= 128 else { return [] }
        let allowed = Suggestions.threshold(forLength: wanted.count)
        let wantedLetters = wanted.sorted()
        var scored: [(distance: Int, order: Int, name: String)] = []
        var seen: Set<String> = []
        for (order, name) in names.enumerated() {
            guard abs(spellings[order].count - wanted.count) <= allowed,
                Suggestions.bagDistance(wantedLetters, letters[order]) <= allowed,
                let distance = Suggestions.distance(wanted, spellings[order], within: allowed),
                seen.insert(name).inserted
            else { continue }
            scored.append((distance, order, name))
        }
        scored.sort { ($0.distance, $0.order) < ($1.distance, $1.order) }
        return scored.prefix(Suggestions.limit).map(\.name)
    }
}
