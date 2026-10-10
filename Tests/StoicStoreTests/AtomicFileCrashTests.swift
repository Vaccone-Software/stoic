@testable import StoicStore
import Testing

/// A deliberately wrong atomic write, so the harness can be shown to fail.
/// Raw bytes, no envelope and no previous generation: the weakest correct
/// form, so every defect has to be caught by the crash model alone.
enum BrokenAtomicWrite {
    case correct
    /// Forgets to flush the temporary file's data before renaming it.
    case skipFullSync
    /// Forgets to sync the directory, so the rename may be lost.
    case skipDirectorySync
    /// Overwrites the file where it stands.
    case writeInPlace
    /// Renames first, flushes after: the name can outrun the data.
    case renameBeforeFullSync

    func write(_ bytes: [UInt8], to path: String, on disk: SimulatedFileSystem) throws {
        let directory = StorePath.directory(of: path)
        if self == .writeInPlace {
            let file = try disk.open(path, mode: .readWriteCreate)
            try disk.write(file, bytes, at: 0)
            try disk.truncate(file, to: bytes.count)
            try disk.fullSync(file)
            try disk.close(file)
            try disk.syncDirectory(directory)
            return
        }
        let temporary = path + ".tmp"
        let file = try disk.open(temporary, mode: .createExclusive)
        try disk.write(file, bytes, at: 0)
        if self != .skipFullSync, self != .renameBeforeFullSync { try disk.fullSync(file) }
        if self == .renameBeforeFullSync {
            try disk.rename(from: temporary, to: path)
            try disk.fullSync(file)
        }
        try disk.close(file)
        if self != .renameBeforeFullSync { try disk.rename(from: temporary, to: path) }
        if self != .skipDirectorySync { try disk.syncDirectory(directory) }
    }
}

/// The invariant of an atomic write over `old`: recovery finds exactly the
/// old bytes or exactly the new, and once the write has returned, the new.
func atomicWriteInvariant(
    path: String,
    old: [UInt8]?,
    new: [UInt8],
    read: @escaping (SimulatedFileSystem) throws -> [UInt8]?
) -> (SimulatedFileSystem, CrashContext) throws -> String? {
    { image, context in
        let found: [UInt8]?
        do {
            found = try read(image)
        } catch {
            return "recovery threw \(error)"
        }
        func describe(_ bytes: [UInt8]?) -> String {
            guard let bytes else { return "nothing" }
            return bytes.count > 16 ? "\(bytes.count) bytes starting \(bytes.prefix(8))" : "\(bytes)"
        }
        if context.reached("returned") {
            guard found == new else { return "write had returned but recovery found \(describe(found)), not the new contents" }
            return nil
        }
        guard found == old || found == new else {
            return "recovery found \(describe(found)): neither the old (\(describe(old))) nor the new (\(describe(new)))"
        }
        // Reading must not change the answer.
        if try read(image) != found { return "a second read returned a different answer" }
        return nil
    }
}

@Suite("AtomicFile crash consistency")
struct AtomicFileCrashTests {
    static let old = (0..<24).map { UInt8($0) &+ 100 }
    static let new = (0..<32).map { UInt8($0) &+ 200 }
    static let large = (0..<700).map { UInt8(truncatingIfNeeded: $0 &* 13) }
    static let path = "/d/settings"

    static func prepare(_ disk: SimulatedFileSystem, existing: [UInt8]?, using file: AtomicFile) throws {
        try disk.createDirectory("/d")
        if let existing { try file.write(existing, to: path) }
    }

    struct Variant: CustomTestStringConvertible, Sendable {
        let envelope: Bool
        let keepPrevious: Bool
        let existing: Bool
        let large: Bool
        var testDescription: String {
            "envelope=\(envelope) previous=\(keepPrevious) existing=\(existing) large=\(large)"
        }
    }

    static let variants: [Variant] = [true, false].flatMap { envelope in
        [true, false].flatMap { previous in
            [true, false].flatMap { existing in
                [false, true].map { Variant(envelope: envelope, keepPrevious: previous, existing: existing, large: $0) }
            }
        }
    }

    @Test(arguments: variants)
    func writeIsAtomicAndDurableAtEveryCrashPoint(variant: Variant) async throws {
        let options = AtomicFile.Options(envelope: variant.envelope, keepPrevious: variant.keepPrevious)
        let old: [UInt8]? = variant.existing ? Self.old : nil
        let new = variant.large ? Self.large : Self.new
        let report = try await exploreCrashes(
            "AtomicFile.write \(variant.testDescription)",
            samples: variant.large ? 8 : 24,
            setup: { try Self.prepare($0, existing: old, using: AtomicFile(fileSystem: $0, options: options)) },
            operation: { disk in
                try AtomicFile(fileSystem: disk, options: options).write(new, to: Self.path)
                disk.checkpoint("returned")
            },
            recovery: { disk in _ = try AtomicFile(fileSystem: disk, options: options).read(Self.path) },
            check: { disk, context in
                let file = AtomicFile(fileSystem: disk, options: options)
                let read: (SimulatedFileSystem) throws -> [UInt8]? = { _ in try file.read(Self.path)?.bytes }
                if let failure = try atomicWriteInvariant(path: Self.path, old: old, new: new, read: read)(disk, context) {
                    return failure
                }
                // A recovered store must be writable again.
                try file.write(Self.old, to: Self.path)
                guard try file.read(Self.path)?.bytes == Self.old else { return "a write after recovery was not read back" }
                return nil
            }
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.crashPoints >= 6)
        #expect(report.images > report.crashPoints)
    }

    @Test func twoWritesInARowKeepTheInvariantAcrossBoth() async throws {
        let options = AtomicFile.Options(keepPrevious: true)
        let report = try await exploreCrashes(
            "AtomicFile.write twice",
            setup: { try Self.prepare($0, existing: Self.old, using: AtomicFile(fileSystem: $0, options: options)) },
            operation: { disk in
                let file = AtomicFile(fileSystem: disk, options: options)
                try file.write(Self.new, to: Self.path)
                disk.checkpoint("first")
                try file.write(Self.large, to: Self.path)
                disk.checkpoint("second")
            },
            check: { disk, context in
                let found = try AtomicFile(fileSystem: disk, options: options).read(Self.path)?.bytes
                if context.reached("second") { return found == Self.large ? nil : "second write acknowledged but lost" }
                if context.reached("first") { return found == Self.new || found == Self.large ? nil : "first write acknowledged but lost" }
                return [Self.old, Self.new, Self.large].contains(found) ? nil : "found neither generation"
            }
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
    }

    /// A private file must never look more open than it was, at any crash
    /// point: not the replacement, not the previous generation.
    @Test(arguments: [true, false])
    func aReplacementIsNeverMoreOpenThanTheFileItReplaces(existing: Bool) async throws {
        let options = AtomicFile.Options(keepPrevious: true, newFileMode: 0o600)
        let report = try await exploreCrashes(
            "AtomicFile.write permissions existing=\(existing)",
            setup: { disk in
                try disk.createDirectory("/d")
                if existing {
                    try AtomicFile(fileSystem: disk, options: options).write(Self.old, to: Self.path)
                    let file = try disk.open(Self.path, mode: .readWrite)
                    try disk.setPermissions(file, to: 0o640)
                    try disk.close(file)
                }
            },
            operation: { disk in
                try AtomicFile(fileSystem: disk, options: options).write(Self.new, to: Self.path)
                try AtomicFile(fileSystem: disk, options: options).write(Self.large, to: Self.path)
            },
            check: { disk, _ in
                let expected: UInt16 = existing ? 0o640 : 0o600
                for name in ["", ".previous"] {
                    let mode = try disk.permissions(of: Self.path + name)
                    if let mode, mode != expected { return "\(Self.path + name) has mode \(String(mode, radix: 8)), expected \(String(expected, radix: 8))" }
                }
                return nil
            }
        )
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
    }

    /// Through a link, the link stays and the target is old or new at every
    /// crash point; once the write returns it is new. Syncing the wrong
    /// directory (the link's) would show here as a lost acknowledged write.
    @Test(arguments: [true, false])
    func aWriteThroughALinkIsAtomicAndKeepsTheLink(keepPrevious: Bool) async throws {
        let options = AtomicFile.Options(keepPrevious: keepPrevious)
        let target = "/real/settings"
        let linked = "/links/settings"
        let report = try await exploreCrashes(
            "AtomicFile.write through a link previous=\(keepPrevious)",
            setup: { disk in
                try disk.createDirectory("/real")
                try disk.createDirectory("/links")
                try AtomicFile(fileSystem: disk, options: options).write(Self.old, to: target)
                disk.symlink(at: linked, to: target)
            },
            operation: { disk in
                try AtomicFile(fileSystem: disk, options: options).write(Self.new, to: linked)
                disk.checkpoint("returned")
            },
            recovery: { disk in _ = try AtomicFile(fileSystem: disk, options: options).read(linked) },
            check: { disk, context in
                if try disk.readLink(linked) != target { return "the link was replaced or lost" }
                let read: (SimulatedFileSystem) throws -> [UInt8]? = { image in try AtomicFile(fileSystem: image, options: options).read(linked)?.bytes }
                if let failure = try atomicWriteInvariant(path: linked, old: Self.old, new: Self.new, read: read)(disk, context) { return failure }
                if try disk.list(directory: "/links") != ["settings"] { return "something was left beside the link: \(try disk.list(directory: "/links"))" }
                return nil
            }
        )
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
        #expect(report.images > report.crashPoints)
    }

    // MARK: The harness must be able to fail

    static func exploreBroken(_ defect: BrokenAtomicWrite) async throws -> CrashReport {
        try await exploreCrashes(
            "broken write: \(defect)",
            setup: { disk in
                try disk.createDirectory("/d")
                try BrokenAtomicWrite.correct.write(Self.old, to: Self.path, on: disk)
            },
            operation: { disk in
                try defect.write(Self.new, to: Self.path, on: disk)
                disk.checkpoint("returned")
            },
            check: atomicWriteInvariant(path: Self.path, old: Self.old, new: Self.new, read: { try? $0.readAll(Self.path) })
        )
    }

    @Test func theCorrectSequenceWithoutTheEnvelopePasses() async throws {
        let report = try await Self.exploreBroken(.correct)
        print(report)
        #expect(report.violations.isEmpty, "\(report.violations.prefix(3).map(\.description).joined(separator: "\n"))")
    }

    @Test(arguments: [BrokenAtomicWrite.skipFullSync, .skipDirectorySync, .writeInPlace, .renameBeforeFullSync])
    func aMissingStepFailsTheCrashCheck(defect: BrokenAtomicWrite) async throws {
        let report = try await Self.exploreBroken(defect)
        print(report)
        for violation in report.violations.prefix(2) { print("  ", violation) }
        #expect(!report.violations.isEmpty, "the harness did not notice \(defect)")
    }

    @Test func theEnvelopeAloneDoesNotRescueAMissingFullSync() async throws {
        // Torn data is *detected* (and the previous generation returned), but
        // the write was acknowledged and then lost: still a violation.
        let options = AtomicFile.Options(keepPrevious: true)
        let report = try await exploreCrashes(
            "enveloped write without fullSync",
            setup: { try Self.prepare($0, existing: Self.old, using: AtomicFile(fileSystem: $0, options: options)) },
            operation: { disk in
                let temporary = Self.path + ".tmp"
                let file = try disk.open(temporary, mode: .createExclusive)
                try disk.write(file, Envelope.seal(Self.new), at: 0)
                try disk.close(file)
                try disk.rename(from: Self.path, to: Self.path + ".previous")
                try disk.rename(from: temporary, to: Self.path)
                try disk.syncDirectory("/d")
                disk.checkpoint("returned")
            },
            check: atomicWriteInvariant(path: Self.path, old: Self.old, new: Self.new, read: {
                try AtomicFile(fileSystem: $0, options: options).read(Self.path)?.bytes
            })
        )
        print(report)
        #expect(!report.violations.isEmpty)
        #expect(report.violations.contains { $0.message.contains("had returned") })
    }
}
