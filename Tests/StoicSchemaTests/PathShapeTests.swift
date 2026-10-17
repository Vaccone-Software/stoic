import StoicJSON
import StoicTesting
import Testing

@testable import StoicSchema

/// An app's settings with a table of routes keyed by hostname and a table of
/// links whose values are objects: the shapes a dotted address has to be read
/// against.
private struct Config: Sendable, Equatable {
    struct Web: Sendable, Equatable {
        struct Link: Sendable, Equatable {
            var url = ""
            var title = ""
        }

        var routes: [String: String] = [:]
        var links: [String: Link] = [:]
        var hosts: [Link] = []
    }

    var speed = 600
    var web = Web()
    var note: String?

    static let linkSchema = Schema.object(Web.Link.self, default: Web.Link()) {
        Field("url", \.url, .string())
        Field("title", \.title, .string())
    }

    static let webSchema = Schema.object(Web.self, default: Web()) {
        Field("routes", \.routes, .dictionary(of: .string()))
        Field("links", \.links, .dictionary(of: linkSchema))
        Field("hosts", \.hosts, .array(of: linkSchema))
    }

    static let schema = Schema.object(Config.self, default: Config()) {
        Field("speed", \.speed, .int())
        Field("web", \.web, webSchema)
        Field("note", \.note, .optional(.string()))
    }
}

private struct Tree: Sendable, Equatable {
    var label = ""
    var children: [String: Tree] = [:]

    static let schema: Schema<Tree> = Schema.object(Tree.self, default: Tree()) {
        Field("label", \.label, .string())
        Field("children", \.children, .dictionary(of: .lazy { Tree.schema }))
    }
}

private func p(_ components: JSONPath.Component...) -> JSONPath { JSONPath(components) }

@Suite("A schema's dotted addresses")
struct PathShapeTests {
    @Test(.failureMode("design/06", "a dotted address has a free key with dots in it"))
    func aDictionaryKeyKeepsItsDotsAndAnObjectFieldDoesNot() {
        let schema = Config.schema
        #expect(schema.path(forAddress: "web.routes.github.com") == p(.key("web"), .key("routes"), .key("github.com")))
        #expect(schema.path(forAddress: "web.links.my.site.url") == p(.key("web"), .key("links"), .key("my.site"), .key("url")))
        #expect(schema.path(forAddress: "web.links.github.com") == p(.key("web"), .key("links"), .key("github.com")))
        #expect(schema.path(forAddress: "speed") == p(.key("speed")))
        #expect(schema.path(forAddress: "web.hosts.2.url") == p(.key("web"), .key("hosts"), .index(2), .key("url")))
        #expect(schema.path(forAddress: "note") == p(.key("note")))
    }

    @Test(.failureMode("design/06", "a dotted address names what the shape does not describe"))
    func anUndeclaredKeyIsReadAsPlainKeys() {
        let schema = Config.schema
        #expect(schema.path(forAddress: "web.nope.a.b") == p(.key("web"), .key("nope"), .key("a"), .key("b")))
        #expect(schema.path(forAddress: "speed.a") == p(.key("speed"), .key("a")))
        #expect(schema.path(forAddress: "web..routes") == nil)
    }

    @Test func aSchemaThatContainsItselfIsReadAsFarAsTheAddressGoes() {
        // A node's children are nodes, through `.lazy`: the shape is never unfolded, only walked.
        #expect(
            Tree.schema.path(forAddress: "children.a.b.children.c.label")
                == p(.key("children"), .key("a.b"), .key("children"), .key("c"), .key("label")))
    }

    @Test func aUnionIsAnObjectWithItsDiscriminatorAndEachCasesFields() {
        let shape = Shape.schema.node.pathShape
        #expect(JSONPath(address: "type", shape: shape) == p(.key("type")))
        #expect(JSONPath(address: "radius", shape: shape) == p(.key("radius")))
        #expect(JSONPath(address: "width", shape: shape) == p(.key("width")))
        #expect(JSONPath(address: "value", shape: shape) == p(.key("value")), "a payload that is not an object sits under the value key")
    }

    @Test func aPathOfAnAddressIsWhereTheSchemaReadsTheValue() throws {
        let path = try #require(Config.schema.path(forAddress: "web.routes.github.com"))
        let document = try JSONValue.object([:]).setting("brave", at: path)
        let decoded = Config.schema.decodeReporting(document.encodedString(style: .compact), options: .strict)
        #expect(decoded.value?.web.routes == ["github.com": "brave"])
    }
}
