#if STOIC_MACROS
import Stoic
import StoicJSON
import StoicMacros
import StoicSchema
import StoicSchemaTesting
import Testing

enum Theme: String, CaseIterable, Sendable, Schematic {
    case light, dark, system
    static var schema: Schema<Theme> { .enumeration(Theme.self) }
}

typealias Port = Refined<IntRange<1, 65_535>>

/// How the app reaches its servers.
@Schema
struct Network: Equatable {
    /// Server names, tried in order.
    @Length(1...253) @Count(0...8) @Unique var hosts: [String] = ["localhost"]
    /// TCP port.
    var port: Port = Port(clamping: 8080)
    @Unit("s") @GreaterThan(0) @Range(...600) var timeoutSeconds: Double = 30
    var useTLS = true
}

extension Network {
    static let byHand = Schema.object(
        Network.self, default: Network(), doc: "How the app reaches its servers."
    ) {
        Field("hosts", \.hosts, .array(of: .string(.length(1...253)), .count(0...8), .unique), doc: "Server names, tried in order.")
        Field("port", \.port, Port.schema, doc: "TCP port.")
        Field("timeoutSeconds", \.timeoutSeconds, .double(.greaterThan(0), .range(...600)), unit: "s")
        Field("useTLS", \.useTLS, .bool)
    }
}

/// Application settings.
@Schema
struct Settings: Equatable {
    /// Pixels per second.
    @Unit("px/s") @Range(200...4000) var scrollSpeed: Double = 1200
    /// Colour scheme.
    var theme: Theme = .system
    /// Credential for the sync service.
    @Key("api_token") @Secret @Length(...128) var apiToken: String = ""
    var network = Network()
    @Range(0...10_000) var maxHistory: Int = 100
    @Length(1...64) var windowTitle: String? = nil
    @Nullable var note: String? = "none"
    @Count(...50) @Length(1...32) var shortcuts: [String: String] = [:]
    /// A lowercase code.
    @Pattern("^[a-z]+$") @Length(...20, unit: .utf8Bytes) var code = "abc"
    /// Every fifth step.
    @MultipleOf(5) @Range(0..<50) var step: Int = 5
    @Aliases("legacy", "old_mode") @Deprecated("Use `theme` instead.") var legacyMode = false
    @Range(1...9) var channel: UInt8 = 3
    @Ignored var cache: [String: Int] = [:]
}

extension Settings {
    static let byHand = Schema.object(Settings.self, default: Settings(), doc: "Application settings.") {
        Field("scrollSpeed", \.scrollSpeed, .double(.range(200...4000)), doc: "Pixels per second.", unit: "px/s")
        Field("theme", \.theme, Theme.schema, doc: "Colour scheme.")
        Field("api_token", \.apiToken, .string(.length(...128)), doc: "Credential for the sync service.", secret: true)
        Field("network", \.network, Network.schema)
        Field("maxHistory", \.maxHistory, .int(.range(0...10_000)))
        Field("windowTitle", \.windowTitle, .optional(.string(.length(1...64))))
        Field("note", \.note, .optional(.string(), nullable: true))
        Field("shortcuts", \.shortcuts, .dictionary(of: .string(.length(1...32)), .count(...50)))
        Field("code", \.code, .string(.pattern("^[a-z]+$"), .length(...20, unit: .utf8Bytes)), doc: "A lowercase code.")
        Field("step", \.step, .int(.multipleOf(5), .range(0..<50)), doc: "Every fifth step.")
        Field("legacyMode", \.legacyMode, .bool, aliases: ["legacy", "old_mode"], deprecated: "Use `theme` instead.")
        Field("channel", \.channel, .integer(UInt8.self, [.range(1...9)]))
    }
}

/// A type whose schema refers to itself.
@Schema
struct Node: Equatable {
    /// Child nodes.
    var children: [Node] = []
    /// The label.
    var label = ""
}

extension Node {
    static let byHand = Schema.object(Node.self, default: Node(), doc: "A type whose schema refers to itself.") {
        Field("children", \.children, .array(of: .lazy { Node.schema }), doc: "Child nodes.")
        Field("label", \.label, .string(), doc: "The label.")
    }
}

/// Holds a `Secret`, which is not `Equatable`.
@Schema
struct Vault {
    /// The token.
    var token: Secret<String> = Secret("")
    /// Keys.
    var spares: [Secret<String>] = []
}

@Suite("@Schema on a struct")
struct StructTests {
    @Test func theMacroWritesTheSchemaAHumanWould() {
        expectEquivalent(Network.schema, Network.byHand)
        expectEquivalent(Settings.schema, Settings.byHand)
    }

    @Test func theTypeIsSchematic() {
        func schema<T: Schematic>(of _: T.Type) -> Schema<T> { T.schema }
        #expect(schema(of: Network.self).node.expectation == Network.schema.node.expectation)
        #expect(schema(of: [Network].self).decode(["1"]).value == nil)
    }

    @Test func theKeyAndTheDocumentationAreInTheExport() throws {
        let export = Settings.schema.jsonSchema()
        let properties = try #require(at(export, "properties")?.object)
        #expect(properties["api_token"] != nil)
        #expect(properties["apiToken"] == nil)
        #expect(properties["cache"] == nil)
        #expect(at(export, "properties", "scrollSpeed", "description") == "Pixels per second.")
        #expect(at(export, "properties", "scrollSpeed", "x-stoic-unit") == "px/s")
        #expect(at(export, "description") == "Application settings.")
    }

    @Test func aSecretKeepsOutOfSparseOutputAndIssues() {
        var settings = Settings()
        settings.apiToken = "hunter2"
        #expect(Settings.schema.encode(settings, style: .sparse).object?["api_token"] == nil)
        #expect(Settings.schema.encode(settings, style: .sparse(includeSecrets: true)).object?["api_token"] == "hunter2")
        let issues = Settings.schema.decode(["api_token": 5]).issues
        #expect(issues.count == 1)
        #expect(issues.allSatisfy { $0.actual == nil })
    }

    @Test func respelledKeysAreAcceptedWithAWarning() {
        let decoded = Settings.schema.decode(["legacy": true])
        #expect(decoded.value?.legacyMode == true)
        #expect(decoded.warnings.count >= 1)
    }

    @Test func aRecursiveTypeReachesItselfLazily() {
        expectEquivalent(Node.schema, Node.byHand, seeds: 0..<4)
        #expect(expectSchemaSuite(Node.schema, seed: 3, cases: 60).isClean)
    }

    @Test func aSecretTypeIsASecretField() throws {
        let export = Vault.schema.jsonSchemaExport()
        _ = export
        var vault = Vault()
        vault.token = Secret("hunter2")
        #expect(Vault.schema.encode(vault, style: .sparse).object?["token"] == nil)
        #expect(Vault.schema.encode(vault).object?["token"] == "hunter2")
        let decoded = Vault.schema.decode(["token": "abc", "spares": ["x", "y"]])
        #expect(decoded.value?.token.reveal() == "abc")
        #expect(decoded.value?.spares.map { $0.reveal() } == ["x", "y"])
        let wrong = Vault.schema.decode(["token": 5])
        #expect(wrong.errors.count == 1)
        #expect(wrong.errors.allSatisfy { $0.actual == nil })
    }

    @Test func theSuiteIsClean() {
        let report = expectSchemaSuite(Settings.schema, seed: 1, cases: 200)
        #expect(report.isClean)
    }

    @Test func theSuiteIsCleanForTheNestedType() {
        #expect(expectSchemaSuite(Network.schema, seed: 2, cases: 200).isClean)
    }
}
#endif
