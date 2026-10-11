import StoicJSON
import StoicTesting
import Testing

@testable import StoicSchema

private func decode<V>(_ schema: Schema<V>, _ text: String, _ options: DecodeOptions = .strict) -> Decoded<V> {
    schema.decodeReporting(text, options: options)
}

@Suite("Migration operations")
struct MigrationOperationTests {
    private func run(_ operations: [Migration.Operation], on text: String) throws -> JSONValue {
        var document = json(text)
        try Migration(from: 1, to: 2, operations: operations).apply(to: &document)
        return document
    }

    @Test func renameKeepsThePlace() throws {
        let result = try run([.rename("b", to: "z")], on: #"{"a": 1, "b": 2, "c": 3}"#)
        #expect(result.object?.keys == ["a", "z", "c"])
        #expect(result.object?["z"] == 2)
    }

    @Test func renameWorksInsideNestedObjects() throws {
        let result = try run([.rename("n.old", to: "new")], on: #"{"n": {"old": 1, "x": 2}}"#)
        #expect(result == json(#"{"n": {"new": 1, "x": 2}}"#))
    }

    @Test func renameOfAMissingPathDoesNothing() throws {
        #expect(try run([.rename("nope", to: "z")], on: #"{"a": 1}"#) == json(#"{"a": 1}"#))
        #expect(try run([.rename("n.old", to: "z")], on: #"{"n": 5}"#) == json(#"{"n": 5}"#))
    }

    @Test func renameOntoATakenKeyIsAFailureNotAnOverwrite() {
        #expect(throws: MigrationFailure.self) { try run([.rename("a", to: "b")], on: #"{"a": 1, "b": 2}"#) }
    }

    @Test func moveCreatesTheObjectsOnTheWay() throws {
        let result = try run([.move("hosts", to: "network.servers.list")], on: #"{"hosts": [1], "keep": true}"#)
        #expect(result == json(#"{"keep": true, "network": {"servers": {"list": [1]}}}"#))
    }

    @Test func moveIntoAnExistingObjectAddsToIt() throws {
        let result = try run([.move("hosts", to: "network.hosts")], on: #"{"hosts": [1], "network": {"port": 80}}"#)
        #expect(result == json(#"{"network": {"port": 80, "hosts": [1]}}"#))
    }

    @Test func moveOntoATakenPathOrThroughANonObjectFails() {
        #expect(throws: MigrationFailure.self) { try run([.move("a", to: "b")], on: #"{"a": 1, "b": 2}"#) }
        #expect(throws: MigrationFailure.self) { try run([.move("a", to: "b.c")], on: #"{"a": 1, "b": 2}"#) }
    }

    @Test func moveOfAMissingPathDoesNothing() throws {
        #expect(try run([.move("nope", to: "x.y")], on: #"{"a": 1}"#) == json(#"{"a": 1}"#))
    }

    @Test func deleteRemovesAtAnyDepthAndSkipsWhatIsNotThere() throws {
        #expect(try run([.delete("a"), .delete("n.x"), .delete("z.y.x")], on: #"{"a": 1, "n": {"x": 1, "y": 2}}"#) == json(#"{"n": {"y": 2}}"#))
    }

    @Test func setIfAbsentOnlyFillsGaps() throws {
        let result = try run(
            [.setIfAbsent("a", 9), .setIfAbsent("b", 9), .setIfAbsent("n.m", "x")], on: #"{"a": 1}"#)
        #expect(result == json(#"{"a": 1, "b": 9, "n": {"m": "x"}}"#))
        // An explicit null is a value: it is not replaced.
        #expect(try run([.setIfAbsent("a", 9)], on: #"{"a": null}"#) == json(#"{"a": null}"#))
    }

    @Test func pinDefaultWritesTheOldDefaultOnlyWhereTheFieldWasLeftOut() throws {
        let pin: [Migration.Operation] = [.pinDefault("speed", 600)]
        #expect(try run(pin, on: "{}") == json(#"{"speed": 600}"#))
        #expect(try run(pin, on: #"{"speed": 1200}"#) == json(#"{"speed": 1200}"#))
    }

    @Test func mapEnumRewritesMappedStringsOnly() throws {
        let map: [Migration.Operation] = [.mapEnum("mode", ["fast": "turbo", "slow": "eco"])]
        #expect(try run(map, on: #"{"mode": "fast"}"#) == json(#"{"mode": "turbo"}"#))
        #expect(try run(map, on: #"{"mode": "normal"}"#) == json(#"{"mode": "normal"}"#))
        #expect(try run(map, on: #"{"mode": 3}"#) == json(#"{"mode": 3}"#))
        #expect(try run(map, on: "{}") == json("{}"))
        #expect(try run([.mapEnum("a.b", ["x": "y"])], on: #"{"a": {"b": "x"}}"#) == json(#"{"a": {"b": "y"}}"#))
    }

    @Test func aCustomOperationEditsTheWholeDocument() throws {
        let operation = Migration.Operation.custom(id: "stamp", apply: { (document: inout JSONValue) throws(MigrationFailure) in
            guard case .object(var object) = document else { throw MigrationFailure("not an object") }
            object["stamped"] = true
            document = .object(object)
        })
        #expect(try run([operation], on: "{}") == json(#"{"stamped": true}"#))
    }

    @Test func aCustomOperationMayFail() {
        let operation = Migration.Operation.custom(id: "boom", apply: { (_: inout JSONValue) throws(MigrationFailure) in
            throw MigrationFailure("no")
        })
        #expect(throws: MigrationFailure(("no"))) { try run([operation], on: "{}") }
    }

    @Test func operationsDescribeThemselves() {
        #expect(Migration.Operation.rename("a.b", to: "c").description == "rename a.b to c")
        #expect(Migration.Operation.move("a", to: "b.c").description == "move a to b.c")
        #expect(Migration.Operation.delete("a").description == "delete a")
        #expect(Migration.Operation.pinDefault("a", 5).description == "pin a to 5")
        #expect(Migration.Operation.setIfAbsent("a", "x").description == #"set a to "x" if absent"#)
        #expect(Migration.Operation.mapEnum("m", ["b": "y", "a": "x"]).description == "map m: a -> x, b -> y")
        #expect(Migration.Operation.custom(id: "c", description: "does it", apply: { (_: inout JSONValue) in }).description == "custom c: does it")
    }

    @Test func operationsAreData() {
        #expect(Migration.Operation.rename("a", to: "b") == .rename("a", to: "b"))
        #expect(Migration.Operation.rename("a", to: "b") != .rename("a", to: "c"))
        #expect(Migration.Operation.mapEnum("m", ["a": "b"]).kind == .mapEnum(path: "m", mapping: ["a": "b"]))
        #expect(Migration.from(1, to: 2, .delete("x")) == Migration(from: 1, to: 2, operations: [.delete("x")]))
        let a = Migration.Operation.custom(id: "same", apply: { (_: inout JSONValue) in })
        let b = Migration.Operation.custom(id: "same", description: "other", apply: { (_: inout JSONValue) in })
        #expect(a == b)
    }

    @Test func inversesUndoWhatTheyCan() throws {
        var document = json(#"{"scrollSpeed": 5, "network": {"hosts": [1]}, "mode": "turbo"}"#)
        let step = Migration.from(
            1, to: 2, .rename("scroll_speed", to: "scrollSpeed"), .move("hosts", to: "network.hosts"),
            .mapEnum("mode", ["fast": "turbo"]))
        guard let inverse = step.inverted() else { return fail("every operation inverts") }
        #expect(inverse.gaps.isEmpty)
        for operation in inverse.operations { try operation.apply(to: &document) }
        #expect(document == json(#"{"scroll_speed": 5, "hosts": [1], "mode": "fast"}"#))
    }

    @Test func aMappingThatMergesTwoValuesHasNoInverse() {
        #expect(Migration.from(1, to: 2, .mapEnum("m", ["a": "x", "b": "x"])).inverted() == nil)
        #expect(Migration.from(1, to: 2, .custom(id: "c", apply: { (_: inout JSONValue) in })).inverted() == nil)
    }

    @Test func aDeleteWithoutAnExampleLeavesAGap() {
        let inverse = Migration.from(1, to: 2, .delete("old")).inverted()
        #expect(inverse?.operations.isEmpty == true)
        #expect(inverse?.gaps.count == 1)
    }
}

@Suite("Versioned objects")
struct VersionedObjectTests {
    @Test func aCurrentDocumentDecodesWithoutIssues() {
        let result = decode(Prefs.schema, #"{"version": 4, "scrollSpeed": 900, "mode": "turbo", "network": {"hosts": ["x"]}}"#)
        #expect(result.issues.isEmpty)
        #expect(result.value == Prefs(scrollSpeed: 900, mode: .turbo, network: Net(hosts: ["x"], timeoutMillis: 30_000)))
    }

    @Test func theVersionKeyIsNotAnUnknownKeyEvenWhereUnknownKeysAreRejected() {
        #expect(decode(Prefs.schema, #"{"version": 4}"#).issues.isEmpty)
        #expect(decode(Prefs.schema, #"{"version": 4, "surprise": 1}"#).issues.locations == ["$.surprise unknown_key"])
    }

    @Test func encodingWritesTheCurrentVersionFirst() {
        let full = Prefs.schema.encode(Prefs(), style: .full)
        #expect(full.object?.keys == ["version", "scrollSpeed", "mode", "network"])
        #expect(full.object?["version"] == 4)
        #expect(Prefs.schema.encode(Prefs(), style: .sparse).encodedString(style: .compact) == #"{"version":4}"#)
        #expect(
            Prefs.schema.encode(Prefs(scrollSpeed: 900), style: .sparse).encodedString(style: .compact)
                == #"{"version":4,"scrollSpeed":900}"#)
    }

    @Test func aDocumentOlderThanTheSchemaIsMigratedStepByStep() {
        let text = #"{"version": 1, "scroll_speed": 900, "mode": "fast", "hosts": ["a"], "legacy": true}"#
        let result = decode(Prefs.schema, text)
        #expect(result.value == Prefs(scrollSpeed: 900, mode: .turbo, network: Net(hosts: ["a"], timeoutMillis: 30_000)))
        #expect(result.issues.map(\.code) == [.migrated, .migrated, .migrated])
        #expect(result.issues.map(\.severity) == [.warning, .warning, .warning])
        #expect(result.issues.map { $0.parameters["from"]?.number?.lexeme } == ["1", "2", "3"])
        #expect(result.issues.map { $0.parameters["to"]?.number?.lexeme } == ["2", "3", "4"])
        #expect(result.issues[0].message == "migrated from version 1 to 2")
        #expect(result.issues[0].path == .root)
        #expect(
            result.issues[1].parameters["operations"]
                == ["move hosts to network.hosts", "map mode: fast -> turbo", "delete legacy", "set network.timeoutSeconds to 30 if absent"])
    }

    @Test func aDocumentPartWayUpTheChainRunsOnlyTheRemainingSteps() {
        let result = decode(Prefs.schema, #"{"version": 3, "network": {"timeoutSeconds": 2}}"#)
        #expect(result.issues.map { $0.parameters["from"]?.number?.lexeme } == ["3"])
        #expect(result.value?.network.timeoutMillis == 2000)
    }

    @Test(.failureMode("design/06", "a default changed between releases")) func pinDefaultKeepsTheValueAnOldDocumentMeant() {
        // Version 1's default speed was 600 and a sparse v1 file omits it.
        // Version 4's default is 1200: without the pin the user's speed
        // would silently double.
        let old = decode(Prefs.schema, #"{"version": 1}"#)
        #expect(old.value?.scrollSpeed == 600)
        #expect(Prefs().scrollSpeed == 1200)
        // The same omission in a current document means the current default.
        #expect(decode(Prefs.schema, #"{"version": 4}"#).value?.scrollSpeed == 1200)
        #expect(decode(Prefs.schema, #"{"version": 2}"#).value?.scrollSpeed == 1200)
        // An explicit value is never touched by the pin.
        #expect(decode(Prefs.schema, #"{"version": 1, "scroll_speed": 1200}"#).value?.scrollSpeed == 1200)
    }

    @Test func aDocumentWithoutAVersionIsTheOldestByDefault() {
        let result = decode(Prefs.schema, #"{"scroll_speed": 300}"#)
        #expect(result.value?.scrollSpeed == 300)
        #expect(result.issues.count == 3)
    }

    @Test func missingVersionMayMeanCurrentOrBeAnError() {
        struct Doc: Sendable, Equatable { var size = 1 }
        func schema(_ missing: MissingVersion) -> Schema<Doc> {
            Schema.object(
                Doc.self, default: Doc(), version: 2, missingVersion: missing,
                migrations: [.from(1, to: 2, .rename("sz", to: "size"))]
            ) {
                Field("size", \.size, .int())
            }
        }
        #expect(decode(schema(.current), #"{"size": 5}"#).value == Doc(size: 5))
        #expect(decode(schema(.current), #"{"size": 5}"#).issues.isEmpty)
        #expect(decode(schema(.oldest), #"{"sz": 5}"#).value == Doc(size: 5))
        let error = decode(schema(.error), #"{"size": 5}"#)
        #expect(error.issues.locations == ["$.version missing_key"])
        #expect(error.value == nil)
    }

    @Test func aNewerVersionIsRefusedWithBothVersionsNamed() {
        let result = decode(Prefs.schema, #"{"version": 5, "scrollSpeed": 900}"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$.version version_too_new"])
        #expect(result.issues[0].message == "version 5 is newer than the newest this app reads, 4")
        #expect(result.issues[0].severity == .error)
        #expect(result.issues[0].source?.start.column == 13)
    }

    @Test func aNewerVersionIsReadAndKeptWhenTheSchemaPreservesUnknownKeys() {
        let text = #"{"version": 7, "name": "kept", "color": "blue", "nested": {"a": [1, 2]}}"#
        let result = decode(Loose.schema, text)
        #expect(result.issues.locations == ["$.version version_too_new"])
        #expect(result.issues[0].severity == .warning)
        #expect(result.issues[0].message.hasSuffix("the fields it adds are kept but not understood"))
        #expect(result.value?.name == "kept")
        #expect(result.value?.extra == json(#"{"version": 7, "color": "blue", "nested": {"a": [1, 2]}}"#).object)
    }

    @Test func savingADocumentFromANewerReleaseDoesNotDowngradeOrDestroyIt() {
        let text = #"{"version": 7, "name": "kept", "color": "blue", "nested": {"a": [1, 2]}}"#
        guard let loaded = decode(Loose.schema, text).value else { return fail("decode") }
        for style in [EncodeStyle.full, .sparse] {
            let written = Loose.schema.encode(loaded, style: style)
            #expect(written.object?["version"] == 7, "\(style)")
            #expect(written.object?["color"] == "blue")
            #expect(written.object?["nested"] == json(#"{"a": [1, 2]}"#))
        }
    }

    @Test func aVersionThatIsNotAPositiveIntegerIsRefused() {
        for (text, code) in [
            (#""4""#, IssueCode.typeMismatch), ("2.5", .typeMismatch), ("null", .typeMismatch), ("true", .typeMismatch),
            ("0", .outOfRange), ("-1", .outOfRange), ("99999999999999999999", .typeMismatch),
        ] {
            let result = decode(Prefs.schema, #"{"version": \#(text)}"#)
            #expect(result.value == nil, "\(text)")
            #expect(result.issues.locations == ["$.version \(code)"], "\(text): \(result.issues.locations)")
        }
        // 4.0 is a whole number in an odd spelling and is the current version.
        #expect(decode(Prefs.schema, #"{"version": 4.0}"#).value == Prefs())
    }

    @Test func aVersionWithNoPathToTheCurrentOneIsUnsupported() {
        struct Doc: Sendable, Equatable { var size = 1 }
        let schema = Schema.object(
            Doc.self, default: Doc(), version: 4,
            migrations: [.from(2, to: 3, .rename("a", to: "b")), .from(3, to: 4, .rename("b", to: "size"))]
        ) {
            Field("size", \.size, .int())
        }
        let result = decode(schema, #"{"version": 1}"#)
        #expect(result.issues.locations == ["$.version version_unsupported"])
        #expect(result.issues[0].message == "version 1 cannot be migrated to version 4; the oldest readable is 2")
        #expect(decode(schema, #"{"version": 2, "a": 7}"#).value == Doc(size: 7))
    }

    @Test func aStepThatCannotBeAppliedIsOneMigrationFailedIssue() {
        let result = decode(Prefs.schema, #"{"version": 1, "scroll_speed": 5, "scrollSpeed": 6}"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$ migration_failed"])
        #expect(result.issues[0].message.hasPrefix("migrating from version 1 to 2 failed: cannot rename"))
        let custom = decode(Prefs.schema, #"{"version": 3, "network": {"timeoutSeconds": 1.5}}"#)
        #expect(custom.issues.locations == ["$ migration_failed"])
    }

    @Test func errorsAfterMigrationAreReportedAtTheNewPaths() {
        let result = decode(Prefs.schema, #"{"version": 1, "scroll_speed": 5, "mode": "ludicrous", "hosts": [""]}"#)
        #expect(result.value == nil)
        #expect(
            result.errors.locations == [
                "$.scrollSpeed out_of_range", "$.mode not_one_of", "$.network.hosts[0] too_short",
            ])
        #expect(result.errors[1].suggestions.isEmpty)
    }

    @Test func issuesInAMigratedDocumentPointAtTheWholeObjectNotAStaleSpot() {
        let text = "{\n  \"version\": 1,\n  \"scroll_speed\": 5\n}"
        let result = decode(Prefs.schema, text)
        let error = result.errors[0]
        #expect(error.path.description == "$.scrollSpeed")
        // The object's range, not the line of `scroll_speed`, which no longer names the field.
        #expect(error.source?.start.line == 1)
        // Without a migration positions stay exact.
        let current = decode(Prefs.schema, "{\n  \"version\": 4,\n  \"scrollSpeed\": 5\n}")
        #expect(current.errors[0].source?.start.line == 3)
    }

    @Test func aMigratedRegionDoesNotLeakToSiblings() {
        struct Pair: Sendable, Equatable {
            var old = Loose()
            var current = Loose()
        }
        let schema = Schema.object(Pair.self, default: Pair(), unknownKeys: .reject) {
            Field("old", \.old, Loose.schema)
            Field("current", \.current, Loose.schema)
        }
        let text = "{\n \"old\": {\"version\": 1, \"title\": \"\"},\n \"current\": {\"version\": 2, \"name\": \"\"}\n}"
        let result = decode(schema, text)
        #expect(result.errors.locations == ["$.old.name too_short", "$.current.name too_short"])
        #expect(result.errors[0].source?.start.line == 2)
        #expect(result.errors[1].source?.start.line == 3)
        #expect(result.errors[1].source?.start.column == 36)
    }

    @Test func lenientDecodingMigratesAndRepairs() {
        let result = decode(Prefs.schema, #"{"version": 1, "scroll_speed": 5, "mode": "fast"}"#, .lenient)
        #expect(result.value?.scrollSpeed == 1200)  // out of range: repaired to the default
        #expect(result.value?.mode == .turbo)
        #expect(result.issues.map(\.severity).filter { $0 == .repaired }.count == 1)
        #expect(result.issues.map(\.code).filter { $0 == .migrated }.count == 3)
    }

    @Test func validateIgnoresMigrationAndVersionNotices() {
        #expect(Prefs.schema.validate(Prefs()).isEmpty)
        #expect(Prefs.schema.validate(Prefs(scrollSpeed: 5)).map(\.code) == [.outOfRange])
    }

    @Test func versionedObjectsInsideACollectionMigrateIndependently() {
        let schema = Schema<[Loose]>.array(of: Loose.schema)
        let result = decode(schema, #"[{"version": 1, "title": "a"}, {"version": 2, "name": "b"}, {"title": "c"}]"#)
        #expect(result.value?.map(\.name) == ["a", "b", "c"])
        #expect(result.issues.locations == ["$[0] migrated", "$[2] migrated"])
    }

    @Test func formBObjectsAreVersionedToo() {
        struct Point: Sendable, Equatable {
            var x: Int
            var y: Int
            var extra = JSONObject()
        }
        let schema = Schema.object(
            Point.self, version: 2, migrations: [.from(1, to: 2, .rename("px", to: "x"), .pinDefault("y", 0))]
        ) { f in
            let x = f.field("x", \.x, .int())
            let y = f.field("y", \.y, .int())
            let extra = f.unknownKeys(\.extra)
            return f.build { v in Point(x: v[x], y: v[y], extra: v[extra]) }
        }
        let migrated = decode(schema, #"{"version": 1, "px": 3, "tag": "a"}"#)
        #expect(migrated.value == Point(x: 3, y: 0, extra: json(#"{"tag": "a"}"#).object ?? JSONObject()))
        #expect(migrated.issues.map(\.code) == [.migrated])
        #expect(schema.encode(migrated.value ?? Point(x: 0, y: 0)).encodedString(style: .compact) == #"{"version":2,"x":3,"y":0,"tag":"a"}"#)
        #expect(decode(schema, #"{"version": 9, "x": 1, "y": 2}"#).issues.map(\.code) == [.versionTooNew])
        #expect(decode(schema, #"{"version": 9, "x": 1, "y": 2}"#).issues[0].severity == .warning)
    }

    @Test func theNodeRecordsTheHistory() {
        guard case .object(let node) = Prefs.schema.node, let versioning = node.versioning else { return fail("node") }
        #expect(versioning.current == 4)
        #expect(versioning.key == "version")
        #expect(versioning.oldest == 1)
        #expect(versioning.missing == .oldest)
        #expect(versioning.migrations.map(\.from) == [1, 2, 3])
        #expect(node.fields.map(\.key) == ["scrollSpeed", "mode", "network"])
    }

    @Test func theExportStatesTheCurrentVersionAndListsTheHistory() {
        let document = Prefs.schema.jsonSchema().object
        let version = document?["properties"]?.object?["version"]?.object
        #expect(version?["const"] == 4)
        #expect(version?["type"] == "integer")
        #expect(document?["required"] == ["version"])
        let history = document?["x-stoic-version"]?.object
        #expect(history?["current"] == 4)
        #expect(history?["oldest"] == 1)
        #expect(history?["migrations"]?.array?.count == 3)
        #expect(history?["migrations"]?.array?[0].object?["operations"] == ["rename scroll_speed to scrollSpeed", "pin scrollSpeed to 600"])
        #expect(document?["additionalProperties"] == false)
    }

    @Test func theExportAgreesWithTheDecoderOnCurrentDocuments() {
        let validator = JSONSchemaValidator(Prefs.schema.jsonSchema())
        let documents = [
            #"{"version": 4}"#, #"{"version": 4, "scrollSpeed": 200}"#, #"{"version": 4, "scrollSpeed": 199}"#,
            #"{"version": 5}"#, #"{"version": 4, "surprise": 1}"#, #"{"version": 4, "network": {"timeoutMillis": 0}}"#,
            #"{"version": "4"}"#, #"{"version": 4, "mode": "fast"}"#,
        ]
        for text in documents {
            let document = json(text)
            #expect(validator.accepts(document) == (Prefs.schema.decode(document).value != nil), "\(text)")
        }
    }

    @Test func aMissingVersionIsNotRequiredWhenItMeansCurrent() {
        struct Doc: Sendable, Equatable { var size = 1 }
        let schema = Schema.object(Doc.self, default: Doc(), version: 2, missingVersion: .current) {
            Field("size", \.size, .int())
        }
        #expect(schema.jsonSchema().object?["required"] == nil)
    }
}

@Suite("Time capsule")
struct TimeCapsuleTests {
    @Test func everyReleasedVersionStillDecodesToWhatItMeant() {
        for entry in PrefsCapsule.entries {
            let result = decode(Prefs.schema, entry.text)
            #expect(result.errors.isEmpty, "version \(entry.version): \(result.issues)")
            #expect(result.value == entry.expected, "version \(entry.version)")
            // Nothing but migration notices.
            #expect(result.issues.allSatisfy { $0.code == .migrated }, "version \(entry.version)")
            #expect(result.issues.count == 4 - entry.version, "version \(entry.version)")
        }
    }

    @Test func everyVersionTheSchemaCanReadHasADocumentInTheCapsule() {
        // The reminder to add a document when a release changes the format:
        // this fails the moment the history grows without a capsule entry.
        guard case .object(let node) = Prefs.schema.node, let versioning = node.versioning else { return fail("node") }
        let kept = Set(PrefsCapsule.entries.map(\.version))
        let readable = Set(versioning.migrations.map(\.from) + [versioning.current])
        #expect(kept == readable)
    }

    @Test func capsuleDocumentsSurviveARoundTripThroughTheCurrentSchema() {
        for entry in PrefsCapsule.entries {
            guard let value = decode(Prefs.schema, entry.text).value else { return fail("decode \(entry.version)") }
            let written = Prefs.schema.encode(value, style: .sparse).encodedString()
            let again = decode(Prefs.schema, written)
            #expect(again.issues.isEmpty, "version \(entry.version)")
            #expect(again.value == value, "version \(entry.version)")
        }
    }
}

@Suite("Preserving unknown keys")
struct PreserveUnknownKeysTests {
    @Test func unknownKeysAreKeptSilentlyAndWrittenBack() {
        let result = decode(Loose.schema, #"{"version": 2, "name": "n", "zeta": 1, "alpha": {"b": [true]}}"#)
        #expect(result.issues.isEmpty)
        #expect(result.value?.extra == json(#"{"zeta": 1, "alpha": {"b": [true]}}"#).object)
        guard let value = result.value else { return fail("decode") }
        let written = Loose.schema.encode(value, style: .sparse)
        #expect(written.object?["zeta"] == 1)
        #expect(written.object?["alpha"] == json(#"{"b": [true]}"#))
        #expect(written.object?.keys == ["version", "name", "zeta", "alpha"])
    }

    @Test func respellingsOfDeclaredKeysAreStillRecognised() {
        let result = decode(Loose.schema, #"{"version": 2, "label": "via alias", "Name": "twice"}"#)
        #expect(result.issues.locations == ["$.name deprecated_key", "$.Name duplicate_key"])
        #expect(result.value == nil)
        let alias = decode(Loose.schema, #"{"version": 2, "label": "via alias"}"#)
        #expect(alias.value?.name == "via alias")
        #expect(alias.value?.extra.isEmpty == true)
    }

    @Test func aFieldWinsOverAPreservedKeyOfTheSameName() {
        var loose = Loose()
        loose.name = "real"
        loose.extra["name"] = "sneaky"
        #expect(Loose.schema.encode(loose, style: .full).object?["name"] == "real")
    }

    @Test func theNodeAndExportSayTheObjectPreserves() {
        guard case .object(let node) = Loose.schema.node else { return fail("node") }
        #expect(node.unknownKeys == .preserve)
        let document = Loose.schema.jsonSchema().object
        #expect(document?["x-stoic-preserves-unknown"] == true)
        #expect(document?["additionalProperties"] == nil)
    }

    @Test func aPreservingObjectAcceptsAnythingElseAValidatorWould() {
        let validator = JSONSchemaValidator(Loose.schema.jsonSchema())
        for text in [#"{"version": 2, "x": 1}"#, #"{"version": 2, "name": ""}"#, #"{"version": 2, "name": "ok"}"#] {
            let document = json(text)
            #expect(validator.accepts(document) == (Loose.schema.decode(document).value != nil), "\(text)")
        }
    }
}

@Suite("Migration chain check")
struct MigrationChainCheckTests {
    struct Doc: Sendable, Equatable {
        var size = 10
        var label = "x"
    }

    private func schema(_ migrations: [Migration], version: Int = 2) -> Schema<Doc> {
        Schema.object(Doc.self, default: Doc(), unknownKeys: .reject, version: version, migrations: migrations) {
            Field("size", \.size, .int(.range(1...100)), doc: "How big.")
            Field("label", \.label, .string(.length(1...8)), doc: "A name.")
        }
    }

    @Test func aSoundHistoryPassesOnEveryStep() {
        let report = Prefs.schema.migrationChainCheck()
        #expect(report.isClean, "\(report)")
        #expect(report.steps.map(\.from) == [1, 2, 3])
        #expect(report.steps.allSatisfy { $0.documentsChecked == 30 && $0.unchecked == nil })
        #expect(report.untested.isEmpty)
        #expect(report.problems.isEmpty)
    }

    @Test func theSameSeedChecksTheSameDocuments() {
        let a = Prefs.schema.migrationChainCheck(cases: 5, seed: 3)
        let b = Prefs.schema.migrationChainCheck(cases: 5, seed: 3)
        #expect(a.description == b.description)
        #expect(a.steps.allSatisfy { $0.documentsChecked == 5 })
    }

    @Test func aStepThatWritesAnInvalidValueIsCaught() {
        // The old document had no size; the migration pins one the schema refuses.
        let report = schema([.from(1, to: 2, .pinDefault("size", 9999))]).migrationChainCheck()
        #expect(!report.isClean)
        #expect(report.steps[0].failures.count == 30)
        #expect(report.steps[0].failures[0].issues.contains { $0.code == .outOfRange })
        #expect(report.description.contains("old document"))
    }

    @Test func aRenameOfAFieldTheSchemaDoesNotHaveIsCaught() {
        let report = schema([.from(1, to: 2, .rename("sz", to: "sizee"))]).migrationChainCheck()
        #expect(!report.isClean)
        #expect(report.steps[0].failures.first?.summary.contains("`sizee`") == true)
    }

    @Test func aMoveToTheWrongPlaceLeavesAnUnknownKeyAndIsCaught() {
        let report = schema([.from(1, to: 2, .move("size_here", to: "inner.size"))]).migrationChainCheck()
        #expect(!report.isClean)
    }

    @Test func anOperationWithNoInverseIsReportedAsUntestedNotPassed() {
        let opaque = Migration.Operation.custom(id: "opaque", apply: { (_: inout JSONValue) in })
        let report = schema([.from(1, to: 2, opaque)]).migrationChainCheck()
        #expect(report.isClean)
        #expect(report.untested.count == 1)
        #expect(report.untested[0].unchecked?.contains("no inverse") == true)
        #expect(report.steps[0].documentsChecked == 0)
    }

    @Test func aMappingThatMergesValuesCannotBeInverted() {
        let report = schema([.from(1, to: 2, .mapEnum("label", ["a": "x", "b": "x"]))]).migrationChainCheck()
        #expect(report.untested.count == 1)
    }

    @Test func aDeleteWithoutAnExampleIsAGapNotAFailure() {
        let report = schema([.from(1, to: 2, .delete("old"))]).migrationChainCheck()
        #expect(report.isClean)
        #expect(report.steps[0].gaps.count == 1)
        #expect(report.steps[0].gaps[0].contains("old"))
        let covered = schema([.from(1, to: 2, .delete("old", example: 5))]).migrationChainCheck()
        // The old document now has `old`, which the migration removes.
        #expect(covered.isClean)
        #expect(covered.steps[0].gaps.isEmpty)
    }

    @Test func aSchemaWithoutVersionsHasNothingToCheck() {
        let report = Settings.schema.migrationChainCheck()
        #expect(report.steps.isEmpty)
        #expect(report.problems.count == 1)
        #expect(!report.isClean)
    }

    @Test func aHistoryWithOnlyTheCurrentVersionHasNoSteps() {
        let report = schema([]).migrationChainCheck()
        #expect(report.steps.isEmpty)
        #expect(report.isClean)
    }
}
