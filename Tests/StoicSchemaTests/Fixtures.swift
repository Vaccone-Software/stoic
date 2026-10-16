import StoicJSON
import StoicSchema

enum Theme: String, CaseIterable, Sendable {
    case light, dark, system
}

enum ZoomRule: ClampableRefinement {
    typealias Base = Double
    static var constraints: [Constraint] { [.range(0.5...5), .finite] }
}
typealias Zoom = Refined<ZoomRule>

/// A nested configuration object.
struct Network: Sendable, Equatable {
    var hosts: [String] = ["localhost"]
    var port: Port = Port(clamping: 8080)
    var timeoutSeconds: Double = 30
    var useTLS = true

    static let schema = Schema.object(Network.self, default: Network(), doc: "How the app reaches its servers.") {
        Field(
            "hosts", \.hosts, .array(of: .string(.length(1...253)), count: 0...8, .unique),
            doc: "Server names, tried in order.", aliases: ["servers"])
        Field("port", \.port, Port.schema, doc: "TCP port.")
        Field("timeoutSeconds", \.timeoutSeconds, .double(.greaterThan(0), .range(...600)), doc: "Request timeout.", unit: "s")
        Field("useTLS", \.useTLS, .bool)
    }
}

/// A realistic configuration type: a bit of everything the declaration
/// supports.
struct Settings: Sendable, Equatable {
    var scrollSpeed: Double = 1200
    var theme: Theme = .system
    var apiToken: String = ""
    var network = Network()
    var maxHistory: Int = 100
    var windowTitle: String? = nil
    var zoom: Zoom = Zoom(clamping: 1)
    var shortcuts: [String: String] = [:]
    var legacyMode = false

    static let schema = Schema.object(Settings.self, default: Settings(), doc: "Application settings.") {
        Field(
            "scrollSpeed", \.scrollSpeed, .double(.range(200...4000)),
            doc: "Pixels per second.", unit: "px/s")
        Field("theme", \.theme, .enumeration(Theme.self), doc: "Colour scheme.")
        Field("apiToken", \.apiToken, .string(.length(...128)), doc: "Credential for the sync service.", secret: true)
        Field("network", \.network, Network.schema)
        Field("maxHistory", \.maxHistory, .int(.range(0...10_000)), doc: "Entries kept.")
        Field("windowTitle", \.windowTitle, .optional(.string(.length(1...64))), doc: "Overrides the title.")
        Field("zoom", \.zoom, Zoom.schema, unit: "×")
        Field("shortcuts", \.shortcuts, .dictionary(of: .string(.length(1...32)), .count(...50)))
        Field("legacyMode", \.legacyMode, .bool, deprecated: "Use `theme` instead.")
    }
}
