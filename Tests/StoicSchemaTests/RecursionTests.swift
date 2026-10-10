import StoicJSON
import Testing

@testable import StoicSchema

/// A recursive configuration: a menu whose items can hold menus.
struct Menu: Sendable, Equatable {
    var title = "Menu"
    var enabled = true
    var items: [Menu] = []
    var fallbacks: [Menu]? = nil

    static let schema: Schema<Menu> = Schema.object(Menu.self, default: Menu(), unknownKeys: .reject) {
        Field("title", \.title, .string(.length(1...20)))
        Field("enabled", \.enabled, .bool)
        Field("items", \.items, .array(of: .lazy { Menu.schema }, .count(...4)))
        Field("fallbacks", \.fallbacks, .optional(.array(of: .lazy { Menu.schema })))
    }
}

@Suite("Recursive schemas")
struct RecursionTests {
    @Test func aRecursiveSchemaIsConstructibleAndDecodes() {
        let text = """
            {"title": "File", "items": [
              {"title": "New", "items": [{"title": "Window"}, {"title": "Tab", "enabled": false}]},
              {"title": "Open"}
            ]}
            """
        let result = Menu.schema.decodeReporting(text)
        #expect(result.issues.isEmpty)
        #expect(result.value?.items.count == 2)
        #expect(result.value?.items[0].items[1].enabled == false)
        #expect(result.value?.items[1].items.isEmpty == true)
    }

    @Test func issuesDeepInTheTreeCarryTheFullPath() {
        let text = """
            {"items": [
              {"title": "ok"},
              {"title": "", "items": [{"title": "fine"}, {"enabled": "no", "items": [{"title": 5}]}]}
            ]}
            """
        let result = Menu.schema.decodeReporting(text)
        #expect(
            result.issues.locations == [
                "$.items[1].title too_short",
                "$.items[1].items[1].enabled type_mismatch",
                "$.items[1].items[1].items[0].title type_mismatch",
            ])
        #expect(result.issues[2].source?.start.line == 3)
    }

    @Test func anOptionalRecursiveFieldDecodesWhenPresent() {
        let result = Menu.schema.decodeReporting(#"{"fallbacks": [{"title": "Backup", "fallbacks": [{"title": "Last"}]}]}"#)
        #expect(result.value?.fallbacks?[0].fallbacks?[0].title == "Last")
        #expect(result.value?.fallbacks?[0].fallbacks?[0].fallbacks == nil)
    }

    @Test func unknownKeysAreRejectedAtEveryLevel() {
        let result = Menu.schema.decodeReporting(#"{"items": [{"itmes": []}]}"#)
        #expect(result.issues.locations == ["$.items[0].itmes unknown_key"])
        #expect(result.issues[0].suggestions == ["items"])
    }

    @Test func roundTripsAtDepth() {
        var menu = Menu(title: "Root")
        var child = Menu(title: "Child")
        child.items = [Menu(title: "Leaf", enabled: false)]
        menu.items = [child, Menu(title: "Other")]
        menu.fallbacks = [Menu(title: "Fallback")]
        let text = Menu.schema.encode(menu).encodedString()
        #expect(Menu.schema.decodeReporting(text).value == menu)
        let sparse = Menu.schema.encode(menu, style: .sparse).encodedString()
        #expect(Menu.schema.decodeReporting(sparse).value == menu)
    }

    @Test func theNodeNamesTheRecursionInsteadOfUnfoldingIt() {
        guard case .object(let node) = Menu.schema.node, case .array(let element, _) = node.fields[2].node,
            case .lazy(let name, let resolve) = element
        else { return fail("node") }
        #expect(name == "Menu")
        guard case .object(let inner) = resolve() else { return fail("resolve") }
        #expect(inner.name == "Menu")
    }

    @Test func aDocumentDeeperThanTheParserAllowsNeverReachesTheSchema() {
        let depth = 100
        let text = String(repeating: #"{"items":["#, count: depth) + String(repeating: "]}", count: depth)
        let result = Menu.schema.decodeReporting(text)
        #expect(result.issues.map(\.code) == [.parseError])
        #expect(result.issues[0].parameters["parseCode"] == "depth_limit")
    }

    @Test func aDeepButAllowedDocumentDecodes() {
        let depth = 30  // each level is two JSON containers: 60 < 64
        let text = String(repeating: #"{"items":["#, count: depth) + "{}" + String(repeating: "]}", count: depth)
        #expect(Menu.schema.decodeReporting(text).value != nil)
    }
}
