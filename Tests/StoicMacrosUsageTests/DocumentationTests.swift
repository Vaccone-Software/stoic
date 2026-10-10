#if STOIC_MACROS
import StoicMacros
import StoicSchema
import Testing

// The examples in README.md and skills/stoic/SKILL.md, compiled. If one of
// them stops being valid Swift, this file stops building.

@Schema enum Theme2: String { case light, dark, system }

/// Application settings.
@Schema
struct DocumentedSettings {
    /// Pixels per second.
    @Range(200...4000) @Unit("px/s") var scrollSpeed: Double = 1200
    var theme: Theme2 = .system
    @Key("api_token") @Secret var apiToken: String = ""
    @Length(1...253) @Count(0...8) @Unique var hosts: [String] = []
}

@Schema(discriminator: "type") enum DocumentedShape {
    case circle(radius: Double)
    case rect(width: Double, height: Double)
    @Key("pt") case point
}

@Refined(Int.self, .range(1...65_535)) enum DocumentedPortRule {}

@Suite("The documented examples")
struct DocumentationTests {
    @Test func theyDoWhatTheyClaim() throws {
        let settings = try DocumentedSettings.schema.decode(#"{"scrollSpeed": 300, "api_token": "t"}"#)
        #expect(settings.scrollSpeed == 300)
        let failure = #expect(throws: ValidationFailure.self) {
            try DocumentedSettings.schema.decode(#"{"scrollSpeed": 5000}"#)
        }
        #expect(failure?.issues.count == 1)
        #expect(try DocumentedShape.schema.decode(#"{"type": "pt"}"#) == .point)
        #expect(throws: ValidationFailure.self) { try Refined<DocumentedPortRule>(0) }
    }
}

extension DocumentedShape: Equatable {}
#endif
