public import Foundation

// The one place StoicTime asks the operating system about zones: the IANA
// database it ships, through Foundation, and the zone the device is set to.
// Everything else in StoicTime is portable arithmetic over the offsets this
// gives (`ZoneRules`), and is tested against scripted rules instead.

extension ZoneRules {
    /// The system's rules: the IANA time zone database the OS ships, through
    /// Foundation's `TimeZone`.
    ///
    /// Its ``version`` is `TimeZone.timeZoneDataVersion`, which an OS update
    /// changes, and its ``deviceZone`` is the zone the device is set to now
    /// (`TimeZone.autoupdatingCurrent`), which travel changes.
    public static let system = ZoneRules(source: SystemZoneRules())
}

/// Foundation's `TimeZone` as a source of offsets.
struct SystemZoneRules: ZoneRulesSource {
    var version: String {
        #if canImport(Darwin)
        TimeZone.timeZoneDataVersion
        #else
        Self.installedVersion
        #endif
    }

    #if !canImport(Darwin)
    /// Off Apple platforms the database's own files say which release is
    /// installed: `tzdata.zi` opens with `# version 2026a`, and some systems
    /// keep a `+VERSION` file. Empty when neither can be read, which a sweep
    /// takes as "unknown: sweep whenever asked".
    private static let installedVersion: String = {
        for path in ["/usr/share/zoneinfo/tzdata.zi", "/usr/share/zoneinfo/+VERSION"] {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let firstLine = String(decoding: data.prefix(64), as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let version = firstLine.replacing("# version", with: "").filter { !$0.isWhitespace }
            if !version.isEmpty { return version }
        }
        return ""
    }()
    #endif

    var deviceZone: TimeZoneID {
        // The device's own zone, read here and only here (design/26): this
        // is the seam every "device zone" in StoicTime goes through.
        TimeZoneID(unchecked: TimeZone.autoupdatingCurrent.identifier)
    }

    func offset(of identifier: String, atSecond second: Int64) -> Int? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        return zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(second)))
    }
}

extension TimeZone {
    /// The zone `id` names, or `nil` if Foundation does not know it: for
    /// formatting a zoned value for people with Foundation's formatters.
    public init?(_ id: TimeZoneID) {
        if let offset = id.fixedOffset {
            self.init(secondsFromGMT: offset)
        } else {
            self.init(identifier: id.identifier)
        }
    }
}

extension TimeZoneID {
    /// The name of `zone`, as Foundation gives it.
    public init(_ zone: TimeZone) {
        self.init(unchecked: zone.identifier)
    }
}
