import StoicJSON
import StoicSchema

/// Random but reproducible values for tests, biased toward the edges where
/// validators go wrong. (Generators derived from schemas are a later layer;
/// these are written by hand for the `Settings` fixture and are what the
/// property tests round-trip.)
struct Gen {
    var random: SeededGenerator

    init(seed: UInt64) {
        random = SeededGenerator(seed: seed)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        // One time in four, an edge of the range.
        if Int.random(in: 0..<4, using: &random) == 0 {
            switch Int.random(in: 0..<4, using: &random) {
            case 0: return range.lowerBound
            case 1: return range.upperBound
            case 2: return min(range.lowerBound + 1, range.upperBound)
            default: return max(range.upperBound - 1, range.lowerBound)
            }
        }
        return Int.random(in: range, using: &random)
    }

    mutating func bool() -> Bool {
        Bool.random(using: &random)
    }

    /// A double in `range` with at most `places` decimals, so that it has a
    /// short exact spelling like the numbers people write.
    mutating func double(_ range: ClosedRange<Double>, places: Int = 3) -> Double {
        let scale = (0..<places).reduce(1.0) { value, _ in value * 10 }
        let low = Int((range.lowerBound * scale).rounded(.up))
        let high = Int((range.upperBound * scale).rounded(.down))
        return Double(int(low...high)) / scale
    }

    /// A string of exactly `count` Unicode scalars, mixing ASCII, accented
    /// letters, CJK, combining marks and astral emoji.
    mutating func string(scalars count: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for _ in 0..<count {
            let value: UInt32
            switch Int.random(in: 0..<10, using: &random) {
            case 0: value = UInt32.random(in: 0xC0...0x17F, using: &random)  // Latin-1/Extended
            case 1: value = UInt32.random(in: 0x4E00...0x4E80, using: &random)  // CJK
            case 2: value = UInt32.random(in: 0x300...0x36F, using: &random)  // combining
            case 3: value = UInt32.random(in: 0x1F600...0x1F64F, using: &random)  // emoji
            case 4: value = UInt32.random(in: 0x20...0x2F, using: &random)  // punctuation incl. quote
            default: value = UInt32.random(in: 0x61...0x7A, using: &random)  // a-z
            }
            if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    mutating func string(scalars range: ClosedRange<Int>) -> String {
        string(scalars: int(range))
    }

    mutating func hosts() -> [String] {
        var seen: Set<[UInt8]> = []
        var hosts: [String] = []
        for _ in 0..<int(0...8) {
            let host = string(scalars: 1...20)
            if seen.insert(Array(host.utf8)).inserted { hosts.append(host) }
        }
        return hosts
    }

    mutating func settings() -> Settings {
        var settings = Settings()
        settings.scrollSpeed = double(200...4000)
        settings.theme = Theme.allCases[Int.random(in: 0..<Theme.allCases.count, using: &random)]
        settings.apiToken = bool() ? "" : string(scalars: 1...128)
        settings.network.hosts = hosts()
        settings.network.port = Port(clamping: int(1...65_535))
        settings.network.timeoutSeconds = double(0.001...600)
        settings.network.useTLS = bool()
        settings.maxHistory = int(0...10_000)
        settings.windowTitle = bool() ? nil : string(scalars: 1...64)
        settings.zoom = Zoom(clamping: double(0.5...5, places: 2))
        var shortcuts: [String: String] = [:]
        for _ in 0..<int(0...5) {
            shortcuts[string(scalars: 1...10)] = string(scalars: 1...32)
        }
        settings.shortcuts = shortcuts
        settings.legacyMode = bool()
        return settings
    }
}
