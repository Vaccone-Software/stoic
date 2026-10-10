#if STOIC_MACROS
import Foundation
import Stoic
import StoicJSON
import StoicMacros
import StoicSchema
import Testing

/// The macros are named for what they say (`Range`, `Unit`, `Secret`, `Count`),
/// and the standard library, Foundation and Stoic have types of those names.
/// Attribute position and type position are looked up apart, so both work in
/// one file, and this file is the proof.
@Schema
struct Lookups: Equatable {
    @Range(1...9) @Unit("items") var count: Int = 3
    @Secret var token = ""
    var window: Range<Int> { 0..<count }
    var measured: Unit? { nil }
    var secret: Secret<String> { Secret(token) }
}

@Suite("Macro names beside the types of the same name")
struct NamingTests {
    @Test func bothMeanWhatTheySay() {
        let value = Lookups()
        #expect(value.window == 0..<3)
        #expect(value.measured == nil)
        #expect(value.secret.reveal() == "")
        #expect(Lookups.schema.decode(["count": 12]).errors.count == 1)
    }
}
#endif
