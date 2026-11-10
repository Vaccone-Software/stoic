import Stoic
import StoicJSON
import StoicSchema
import StoicSettings

// The settings Stoic's compatibility fixtures hold (design/32), as 0.7.0
// recorded them in Compatibility/. The definitions are part of the fixtures:
// they change only with them, never to make a reading pass.

/// Settings with a nested object, a list and a migrated key, as an app keeps
/// them in a settings file.
struct CompatPrefs: Sendable, Equatable {
    struct Editor: Sendable, Equatable {
        var tabWidth = 4
        var wrap = true
    }

    var theme = "system"
    var fontSize = 13
    var recent: [String] = []
    var editor = Editor()

    static let editorSchema = Schema.object(Editor.self, default: Editor(), doc: "The editor.") {
        Field("tabWidth", \.tabWidth, .int(.range(1...16)), doc: "Spaces per tab.")
        Field("wrap", \.wrap, .bool, doc: "Wrap long lines.")
    }

    /// Version 2: `font_size` became `fontSize`.
    static let schema = Schema.object(
        CompatPrefs.self, default: CompatPrefs(), doc: "Preferences.", version: 2,
        migrations: [.from(1, to: 2, .rename("font_size", to: "fontSize"))]
    ) {
        Field("theme", \.theme, .string(.length(1...20)), doc: "The theme.")
        Field("fontSize", \.fontSize, .int(.range(6...72)), doc: "The font size.", unit: "pt")
        Field("recent", \.recent, .array(of: .string(), count: 0...10), doc: "Recent files.")
        Field("editor", \.editor, editorSchema, doc: "The editor.")
    }

    static let header: SettingsFileHeader = ["$schema": "https://example.com/prefs.schema.json"]

    /// The values the fixtures hold, by name.
    static let tuned = CompatPrefs(theme: "dark", fontSize: 15, recent: ["/Users/ana/notes.txt"], editor: Editor(tabWidth: 2, wrap: false))
    static let named: [String: CompatPrefs] = ["tuned": tuned, "defaults": CompatPrefs()]
}
