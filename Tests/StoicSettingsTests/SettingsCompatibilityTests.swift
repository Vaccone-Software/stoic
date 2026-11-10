import Foundation
import Stoic
import StoicJSON
import StoicSchema
import StoicSchemaTesting
import StoicSettings
import StoicStore
import StoicTesting
import Testing

/// Settings files released builds wrote, read by this one (design/32): the
/// fixtures in Compatibility/, each recorded by the release in its folder's
/// name, with that release's own code.
@Suite("Settings: the files released builds wrote")
struct SettingsCompatibilityTests {
    static let options = SettingsStore<CompatPrefs>.Options(handEdited: HandEditedOptions(fileHeader: CompatPrefs.header))
    static let reader = CompatPrefs.schema.jsonSchema(options: JSONSchemaOptions(extraRootProperties: CompatPrefs.header.jsonSchemaProperties))
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Compatibility")

    /// What each fixture must read as: the value it was recorded from.
    @Sendable static func verify(_ fixture: CompatibilityFixture, _ value: CompatPrefs) -> [String] {
        guard let expected = CompatPrefs.named[fixture.name] else { return ["no value is named \"\(fixture.name)\""] }
        return value == expected ? [] : ["reads as \(value), not as \(expected)"]
    }

    @Test func aHandEditedFileReadsAsTheReleaseWroteIt() {
        let report = expectCompatibility(
            CompatPrefs.schema, format: "settings.hand-edited", samples: ["tuned": .tuned, "defaults": CompatPrefs()],
            reading: { SettingsStore<CompatPrefs>.read($0, schema: CompatPrefs.schema, format: .handEdited, options: Self.options) },
            reader: Self.reader, verify: Self.verify)
        #expect(report.read >= 2, "every released file was read")
    }

    /// The file today's store writes, offered to each release's reader as it
    /// is on disk: with its header and its version key.
    @Test func whatTheStoreWritesTodayEveryReleaseReads() throws {
        let set = try loadCompatibilitySet(format: "settings.hand-edited", from: Self.directory.path)
        #expect(!set.readers.isEmpty)
        for value in [CompatPrefs.tuned, CompatPrefs()] {
            let disk = SimulatedFileSystem()
            try disk.createDirectory("/d")
            let store = try SettingsStore.open(
                at: "/d/prefs.json", schema: CompatPrefs.schema, format: .handEdited, fileSystem: disk, options: Self.options)
            // As 0.7.0's were: a store with nothing changed writes nothing.
            try store.update { $0 = .tuned }
            try store.update { $0 = value }
            let written = try JSONValue(parsing: try #require(disk.contents(of: "/d/prefs.json")))
            for (release, reader) in set.readers {
                let violations = JSONSchemaValidator(reader).violations(written)
                #expect(violations.isEmpty, "release \(release)'s reader refuses today's file: \(violations)")
            }
        }
    }

    /// An app-owned file is enveloped, so its fixtures are the file's bytes
    /// (`.bin`), read through the envelope as the store reads them.
    @Test func anAppOwnedFileReadsThroughItsEnvelope() throws {
        let fixtures = try binaryFixtures("settings.app-owned", in: Self.directory)
        var check = CompatibilityCheck(CompatPrefs.schema, options: .lenient)
        check.reading = { SettingsStore<CompatPrefs>.read($0, schema: CompatPrefs.schema) }
        check.generated = 0
        check.verify = Self.verify
        let report = check.report(CompatibilitySet(format: "settings.app-owned", fixtures: fixtures))
        #expect(report.failures.isEmpty, "\(report)")
        #expect(report.read == fixtures.count && !fixtures.isEmpty)
        // No release kept a reader for the envelope: it is code, not a schema.
        #expect(Set(report.warnings.map(\.code)) == ["no_reader"], "\(report)")
    }

    /// With no reader to offer today's file to, the proof that a release
    /// reads it is that today's store writes the very bytes that release did.
    @Test func theStoreWritesTheBytes070Wrote() throws {
        let recorded = try #require(try binaryFixtures("settings.app-owned", in: Self.directory).first { $0.release == ReleaseVersion("0.7.0") })
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/d")
        let store = try SettingsStore.open(at: "/d/app.json", schema: CompatPrefs.schema, fileSystem: disk)
        try store.update { $0 = try #require(CompatPrefs.named[recorded.name]) }
        #expect(disk.contents(of: "/d/app.json") == recorded.bytes)
        // And the file 0.7.0 left is opened as it is, not repaired.
        let left = SimulatedFileSystem()
        try left.createDirectory("/d")
        try AtomicFile(fileSystem: left, options: .init(envelope: false)).write(recorded.bytes, to: "/d/app.json")
        let reopened = try SettingsStore.open(at: "/d/app.json", schema: CompatPrefs.schema, fileSystem: left)
        #expect(reopened.value == CompatPrefs.named[recorded.name])
        #expect(reopened.issues.isEmpty)
        #expect(left.contents(of: "/d/app.json") == recorded.bytes)
    }
}

/// Every `<directory>/<format>/<release>/*.bin`: fixtures of a format whose
/// files are not JSON, so `loadCompatibilitySet` does not read them.
func binaryFixtures(_ format: String, in directory: URL) throws -> [CompatibilityFixture] {
    let root = directory.appending(path: format)
    var fixtures: [CompatibilityFixture] = []
    for folder in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
        let release = try #require(ReleaseVersion(folder), "\(format)/\(folder) is not named for a release")
        for file in try FileManager.default.contentsOfDirectory(atPath: root.appending(path: folder).path).sorted() where file.hasSuffix(".bin") {
            let bytes = try Data(contentsOf: root.appending(path: folder).appending(path: file))
            fixtures.append(CompatibilityFixture(release: release, name: String(file.dropLast(".bin".count)), bytes: Array(bytes)))
        }
    }
    return fixtures
}
