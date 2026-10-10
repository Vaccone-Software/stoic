import Foundation
@testable import Stoic
import Testing

@Suite("Event catalog")
struct EventCatalogTests {
    /// Every event name written as a literal in any product's sources.
    static func emittedNames() throws -> Set<String> {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let pattern = try Regex(#""((?:channel|deadline|race|recur|retry|scope|semaphore|service|singleflight|slot|statemachine|supervisor|abandoned|saga|hedge|breaker|limiter|bulkhead|lifecycle|ratelimiter)\.[a-z_]+)""#)
        let pattern = try Regex(#""((?:channel|deadline|race|recur|retry|scope|semaphore|service|singleflight|slot|statemachine|supervisor|abandoned|saga|hedge|breaker|limiter|bulkhead|lifecycle|store)\.[a-z_]+)""#)
        var names: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift", file.lastPathComponent != "EventCatalog.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: pattern) {
                if let name = match.output[1].substring { names.insert(String(name)) }
            }
        }
        return names
    }

    @Test func everyEmittedEventIsCatalogued() throws {
        let catalogued = Set(EventCatalog.entries.map(\.name.rawValue))
        let missing = try Self.emittedNames().subtracting(catalogued)
        #expect(missing.isEmpty, "emitted but not in EventCatalog: \(missing.sorted())")
    }

    @Test func everyCataloguedEventIsEmitted() throws {
        let emitted = try Self.emittedNames()
        let stale = Set(EventCatalog.entries.map(\.name.rawValue)).subtracting(emitted)
        #expect(stale.isEmpty, "in EventCatalog but never emitted: \(stale.sorted())")
    }

    @Test func theCatalogIsSortedAndUnique() {
        let names = EventCatalog.entries.map(\.name.rawValue)
        #expect(names == names.sorted())
        #expect(Set(names).count == names.count)
    }
}
