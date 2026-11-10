/// A release of the app: one to four dot-separated numbers and an optional
/// pre-release, ordered as semantic versions are (design/32).
///
/// `2.10.0` comes after `2.9.1`; `2.4.0-beta.1` before `2.4.0`; a missing
/// number is 0, so `2.4` is `2.4.0`. Pre-release identifiers compare as
/// semantic versioning says: numbers numerically, below words, which compare
/// by their characters; a shorter list of equal identifiers comes first.
public struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The numbers, padded to four.
    private let numbers: [Int]
    private let prerelease: [String]
    /// The text it was read from.
    public let description: String

    /// The release `text` names, or nil when it is not a version.
    public init?(_ text: String) {
        let (core, pre) = Self.split(text)
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        var identifiers: [String] = []
        if let pre {
            identifiers = pre.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard identifiers.allSatisfy({ identifier in
                !identifier.isEmpty && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }) else { return nil }
        }
        self.numbers = numbers + Array(repeating: 0, count: 4 - numbers.count)
        self.prerelease = identifiers
        self.description = text
    }

    private static func split(_ text: String) -> (core: Substring, prerelease: Substring?) {
        guard let dash = text.firstIndex(of: "-") else { return (text[...], nil) }
        return (text[..<dash], text[text.index(after: dash)...])
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(numbers)
        hasher.combine(prerelease)
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        // A release comes after its pre-releases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case (let a?, let b?): return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
