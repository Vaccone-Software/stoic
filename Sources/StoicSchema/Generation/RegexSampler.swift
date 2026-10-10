/// Makes strings that match a regular expression, for the subset of the
/// syntax that configuration patterns use: literals, `.`, character classes
/// with ranges and negation, the escapes `\d \w \s` (and their capitals) and
/// escaped punctuation, groups, alternation, the quantifiers `* + ? {n}
/// {n,} {n,m}`, and anchors (which sample as nothing; the pattern is found
/// anywhere in a string, so a string that matches the anchored form matches
/// the unanchored one).
///
/// Anything else (lookaround, back-references, Unicode properties) makes
/// ``init(pattern:)`` return `nil` and the generator treat the pattern as
/// opaque. The sampler is a convenience for the generator, never the judge:
/// whatever it makes is checked with the real `Regex` before use.
struct RegexSampler: Sendable {
    indirect enum Node: Sendable {
        case empty
        case literal(Unicode.Scalar)
        case anyCharacter
        case set([ClosedRange<UInt32>], negated: Bool)
        case sequence([Node])
        case choice([Node])
        case `repeat`(Node, minimum: Int, maximum: Int?)
    }

    let root: Node

    init?(pattern: String) {
        var parser = Parser(Array(pattern.unicodeScalars))
        guard let node = parser.parseChoice(), parser.atEnd else { return nil }
        root = node
    }

    /// One matching string. `short` prefers the fewest repetitions.
    func sample(using random: inout SplitMix64, short: Bool) -> String {
        var out = String.UnicodeScalarView()
        emit(root, into: &out, random: &random, short: short)
        return String(out)
    }

    private func emit(_ node: Node, into out: inout String.UnicodeScalarView, random: inout SplitMix64, short: Bool) {
        switch node {
        case .empty:
            break
        case .literal(let scalar):
            out.append(scalar)
        case .anyCharacter:
            out.append(Self.pick(from: [0x61...0x7A, 0x30...0x39, 0x41...0x5A], random: &random))
        case .set(let ranges, let negated):
            if negated {
                let candidates = (0x20...0x7E as ClosedRange<UInt32>).filter { code in
                    !ranges.contains { $0.contains(code) }
                }
                if let code = candidates.randomElement(using: &random), let scalar = Unicode.Scalar(code) {
                    out.append(scalar)
                } else {
                    out.append("\u{E9}")
                }
            } else {
                out.append(Self.pick(from: ranges, random: &random))
            }
        case .sequence(let parts):
            for part in parts { emit(part, into: &out, random: &random, short: short) }
        case .choice(let options):
            emit(options[Int.random(in: 0..<options.count, using: &random)], into: &out, random: &random, short: short)
        case .repeat(let inner, let minimum, let maximum):
            let limit = min(maximum ?? minimum + 3, minimum + 6)
            let count: Int
            if short {
                count = minimum
            } else {
                switch Int.random(in: 0..<4, using: &random) {
                case 0: count = minimum
                case 1: count = limit
                default: count = Int.random(in: minimum...max(minimum, limit), using: &random)
                }
            }
            for _ in 0..<count { emit(inner, into: &out, random: &random, short: short) }
        }
    }

    private static func pick(from ranges: [ClosedRange<UInt32>], random: inout SplitMix64) -> Unicode.Scalar {
        guard !ranges.isEmpty else { return "a" }
        let total = ranges.reduce(0) { $0 + Int($1.count) }
        var index = Int.random(in: 0..<max(total, 1), using: &random)
        for range in ranges {
            if index < range.count {
                return Unicode.Scalar(range.lowerBound + UInt32(index)) ?? "a"
            }
            index -= range.count
        }
        return "a"
    }

    // MARK: Parsing

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var position = 0

        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        var atEnd: Bool { position >= scalars.count }

        private var current: Unicode.Scalar? { position < scalars.count ? scalars[position] : nil }

        mutating func parseChoice() -> Node? {
            var options: [Node] = []
            guard let first = parseSequence() else { return nil }
            options.append(first)
            while current == "|" {
                position += 1
                guard let next = parseSequence() else { return nil }
                options.append(next)
            }
            return options.count == 1 ? options[0] : .choice(options)
        }

        private mutating func parseSequence() -> Node? {
            var parts: [Node] = []
            while let scalar = current, scalar != "|", scalar != ")" {
                guard let atom = parseAtom() else { return nil }
                guard let quantified = parseQuantifiers(atom) else { return nil }
                parts.append(quantified)
            }
            return parts.isEmpty ? .empty : (parts.count == 1 ? parts[0] : .sequence(parts))
        }

        private mutating func parseQuantifiers(_ atom: Node) -> Node? {
            var node = atom
            while let scalar = current {
                var minimum = 0
                var maximum: Int?
                switch scalar {
                case "*": position += 1
                case "+": position += 1; minimum = 1
                case "?": position += 1; maximum = 1
                case "{":
                    guard let bounds = parseBraces() else { return nil }
                    (minimum, maximum) = bounds
                default:
                    return node
                }
                // A lazy or possessive marker changes nothing about what matches.
                if current == "?" || current == "+" { position += 1 }
                node = .repeat(node, minimum: minimum, maximum: maximum)
            }
            return node
        }

        private mutating func parseBraces() -> (Int, Int?)? {
            let start = position
            position += 1
            func number() -> Int? {
                var value: Int?
                while let scalar = current, (0x30...0x39).contains(scalar.value) {
                    let next = (value ?? 0) * 10 + Int(scalar.value - 0x30)
                    if next > 1000 { return nil }
                    value = next
                    position += 1
                }
                return value
            }
            guard let low = number() else {
                position = start
                return nil
            }
            if current == "}" {
                position += 1
                return (low, low)
            }
            guard current == "," else { return nil }
            position += 1
            if current == "}" {
                position += 1
                return (low, nil)
            }
            guard let high = number(), current == "}", high >= low else { return nil }
            position += 1
            return (low, high)
        }

        private mutating func parseAtom() -> Node? {
            guard let scalar = current else { return nil }
            position += 1
            switch scalar {
            case ".": return .anyCharacter
            case "^", "$": return .empty
            case "(":
                if current == "?" {
                    // Only the non-capturing group is understood.
                    guard position + 1 < scalars.count, scalars[position + 1] == ":" else { return nil }
                    position += 2
                }
                guard let inner = parseChoice(), current == ")" else { return nil }
                position += 1
                return inner
            case "[": return parseSet()
            case "\\": return parseEscape(inSet: false)
            case "*", "+", "?", "{": return nil
            default: return .literal(scalar)
            }
        }

        private mutating func parseEscape(inSet: Bool) -> Node? {
            guard let scalar = current else { return nil }
            position += 1
            switch scalar {
            case "d": return .set([0x30...0x39], negated: false)
            case "D": return .set([0x30...0x39], negated: true)
            case "w": return .set([0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x5F...0x5F], negated: false)
            case "W": return .set([0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x5F...0x5F], negated: true)
            case "s": return .set([0x20...0x20, 0x09...0x09], negated: false)
            case "S": return .set([0x20...0x20, 0x09...0x09], negated: true)
            case "t": return .literal("\t")
            case "n": return .literal("\n")
            case "b", "B": return inSet ? .literal("\u{8}") : .empty
            case "1"..."9", "p", "P", "k", "u", "x", "c", "A", "z", "Z", "G", "R", "X", "N", "h", "H", "v", "V", "K":
                return nil
            default:
                return .literal(scalar)
            }
        }

        private mutating func parseSet() -> Node? {
            var negated = false
            if current == "^" {
                negated = true
                position += 1
            }
            var ranges: [ClosedRange<UInt32>] = []
            var first = true
            while let scalar = current {
                if scalar == "]" && !first {
                    position += 1
                    return .set(ranges, negated: negated)
                }
                first = false
                position += 1
                var low = scalar.value
                if scalar == "[" { return nil }  // POSIX classes and nested sets
                if scalar == "\\" {
                    guard let escaped = parseEscape(inSet: true) else { return nil }
                    switch escaped {
                    case .literal(let literal): low = literal.value
                    case .set(let inner, let innerNegated):
                        guard !innerNegated else { return nil }
                        ranges.append(contentsOf: inner)
                        continue
                    default: return nil
                    }
                }
                if current == "-", position + 1 < scalars.count, scalars[position + 1] != "]" {
                    position += 1
                    var high = scalars[position].value
                    position += 1
                    if high == 0x5C {
                        guard let escaped = parseEscape(inSet: true), case .literal(let literal) = escaped else { return nil }
                        high = literal.value
                    }
                    guard high >= low else { return nil }
                    ranges.append(low...high)
                } else {
                    ranges.append(low...low)
                }
            }
            return nil
        }
    }
}
