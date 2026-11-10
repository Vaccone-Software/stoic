import StoicJSON
import StoicSchema
import StoicSchemaTesting

enum Mode: String, CaseIterable, Sendable {
    case slow, normal, turbo
}

struct Net: Sendable, Equatable {
    var hosts: [String] = ["localhost"]
    var timeoutMillis = 30_000

    static let schema = Schema.object(Net.self, default: Net(), unknownKeys: .reject, doc: "Connection settings.") {
        Field("hosts", \.hosts, .array(of: .string(.length(1...253)), count: 0...8), doc: "Server names, tried in order.")
        Field("timeoutMillis", \.timeoutMillis, .int(.range(1...600_000)), doc: "Request timeout.", unit: "ms")
    }
}

/// A configuration with four releases of history. Each release changed the
/// format, and release 2 also changed a default, which is what `pinDefault`
/// is for.
///
///     v1  scroll_speed (default 600), mode (slow|normal|fast), hosts, legacy
///     v2  scroll_speed renamed scrollSpeed; its default became 1200
///     v3  hosts moved under network, fast became turbo, legacy deleted,
///         network.timeoutSeconds added
///     v4  network.timeoutSeconds became network.timeoutMillis
struct Prefs: Sendable, Equatable {
    var scrollSpeed: Double = 1200
    var mode = Mode.normal
    var network = Net()

    static let history: [Migration] = [
        .from(
            1, to: 2,
            .rename("scroll_speed", to: "scrollSpeed"),
            .pinDefault("scrollSpeed", 600)),
        .from(
            2, to: 3,
            .move("hosts", to: "network.hosts"),
            .mapEnum("mode", ["fast": "turbo"]),
            .delete("legacy", example: true),
            .setIfAbsent("network.timeoutSeconds", 30)),
        .from(
            3, to: 4,
            .custom(
                id: "secondsToMillis", description: "network.timeoutSeconds becomes network.timeoutMillis",
                apply: { (document: inout JSONValue) throws(MigrationFailure) in
                    guard case .object(var root) = document, case .object(var network)? = root["network"],
                        let seconds = network["timeoutSeconds"]
                    else { return }
                    guard let number = seconds.number?.int64 else {
                        throw MigrationFailure("network.timeoutSeconds is not a whole number of seconds")
                    }
                    network["timeoutSeconds"] = nil
                    network["timeoutMillis"] = .number(JSONNumber(number * 1000))
                    root["network"] = .object(network)
                    document = .object(root)
                },
                inverse: { (document: inout JSONValue) throws(MigrationFailure) in
                    guard case .object(var root) = document, case .object(var network)? = root["network"],
                        let millis = network["timeoutMillis"]?.number?.int64
                    else { return }
                    network["timeoutMillis"] = nil
                    network["timeoutSeconds"] = .number(JSONNumber(max(1, millis / 1000)))
                    root["network"] = .object(network)
                    document = .object(root)
                })),
    ]

    static let schema = Schema.object(
        Prefs.self, default: Prefs(), unknownKeys: .reject, doc: "Preferences.", version: 4, migrations: history
    ) {
        Field("scrollSpeed", \.scrollSpeed, .double(.range(200...4000)), doc: "Pixels per second.", unit: "px/s")
        Field("mode", \.mode, .enumeration(Mode.self), doc: "How fast it feels.")
        Field("network", \.network, Net.schema, doc: "Connection settings.")
    }
}

/// The time capsule: a document as each released version wrote it, kept for
/// good, as compatibility fixtures (design/32) in `Compatibility/prefs/`, one
/// release per version of the format. Each must still decode to the value it
/// meant, under today's schema, with only `migrated` notices to say so. When a
/// release changes the format, its document is recorded before anything else.
enum PrefsCapsule {
    /// `Compatibility/` beside this file.
    static var directory: String {
        var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
        parts.removeLast()
        return parts.joined(separator: "/") + "/Compatibility"
    }

    /// The value each release's document meant, by release.
    static let expected: [String: Prefs] = [
        // Version 1 wrote the defaults sparsely: no scroll_speed means 600.
        "1.0.0": Prefs(scrollSpeed: 600, mode: .turbo, network: Net(hosts: ["a.example", "b.example"], timeoutMillis: 30_000)),
        "1.1.0": Prefs(scrollSpeed: 900, mode: .slow, network: Net(hosts: ["c.example"], timeoutMillis: 30_000)),
        "1.2.0": Prefs(scrollSpeed: 1200, mode: .turbo, network: Net(hosts: [], timeoutMillis: 5000)),
        "2.0.0": Prefs(scrollSpeed: 3000, mode: .normal, network: Net(hosts: ["localhost"], timeoutMillis: 250)),
    ]

    static func set() throws -> CompatibilitySet {
        try loadCompatibilitySet(format: "prefs", from: directory)
    }
}

/// A configuration that keeps what it does not understand.
struct Loose: Sendable, Equatable {
    var name = "untitled"
    var extra = JSONObject()

    static let schema = Schema.object(
        Loose.self, default: Loose(), doc: "Keeps unknown keys.", version: 2,
        migrations: [.from(1, to: 2, .rename("title", to: "name"))],
        preservingUnknownKeysIn: \Loose.extra
    ) {
        Field("name", \.name, .string(.length(1...40)), doc: "A name.", aliases: ["label"])
    }
}
