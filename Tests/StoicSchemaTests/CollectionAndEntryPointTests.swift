import StoicJSON
import Testing

@testable import StoicSchema

@Suite("Arrays")
struct ArraySchemaTests {
    @Test func decodesEveryElement() {
        let schema = Schema.array(of: .int())
        #expect(schema.decodeReporting("[1, 2, 3]").value == [1, 2, 3])
        #expect(schema.decodeReporting("[]").value == [])
    }

    @Test func threeBadElementsAreThreeIssuesAtTheirIndexes() {
        let schema = Schema.array(of: .int())
        let result = schema.decodeReporting(#"[1, "x", 3, null, 5, 2.5, 7]"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$[1] type_mismatch", "$[3] type_mismatch", "$[5] type_mismatch"])
    }

    @Test func nestedArraysHaveNestedPaths() {
        let schema = Schema.array(of: .array(of: .int(.range(0...9))))
        let result = schema.decodeReporting("[[1, 2], [3, 40], [], [5, 6, -1]]")
        #expect(result.issues.locations == ["$[1][1] out_of_range", "$[3][2] out_of_range"])
    }

    @Test func notAnArrayIsOneMismatch() {
        let result = Schema.array(of: .int()).decodeReporting(#"{"a":1}"#)
        #expect(result.issues.locations == ["$ type_mismatch"])
        #expect(result.issues[0].expected == "an array")
    }

    @Test func countAndUniquenessApply() {
        let schema = Schema.array(of: .int(), .count(1...3), .unique)
        #expect(schema.decodeReporting("[1, 2]").value == [1, 2])
        #expect(schema.decodeReporting("[]").issues.locations == ["$ too_few"])
        #expect(schema.decodeReporting("[1, 2, 3, 4]").issues.locations == ["$ too_many"])
        #expect(schema.decodeReporting("[1, 2, 1]").issues.locations == ["$[2] not_unique"])
    }

    @Test func elementAndArrayProblemsAreAllReported() {
        let schema = Schema.array(of: .int(), .count(...2))
        let result = schema.decodeReporting(#"["a", 2, 3]"#)
        #expect(result.issues.locations == ["$ too_many", "$[0] type_mismatch"])
    }

    @Test func countSugar() {
        let schema = Schema.array(of: .string(), count: 0...2)
        #expect(schema.decodeReporting(#"["a","b","c"]"#).issues.locations == ["$ too_many"])
        guard case .array(_, let constraints) = schema.node else { return fail("node") }
        #expect(constraints == [.count(0...2)])
    }

    @Test func encodesInOrderAndReportsUnwritableElementsAtTheirIndex() {
        let schema = Schema.array(of: .double())
        #expect(schema.encode([1, 2.5]).encodedString() == "[1,2.5]")
        let issues = schema.validate([1, .nan, 3, .infinity])
        #expect(issues.locations == ["$[1] not_finite", "$[3] not_finite"])
    }

    @Test func schematicArraysComposeFromTheirElements() {
        #expect([[Int]].schema.decodeReporting("[[1],[2,3]]").value == [[1], [2, 3]])
        #expect([String].schema.decodeReporting("[1]").issues.locations == ["$[0] type_mismatch"])
    }
}

@Suite("Dictionaries")
struct DictionarySchemaTests {
    @Test func decodesEveryEntry() {
        let schema = Schema.dictionary(of: .int())
        #expect(schema.decodeReporting(#"{"a":1,"b":2}"#).value == ["a": 1, "b": 2])
        #expect(schema.decodeReporting("{}").value == [:])
    }

    @Test func badValuesAreReportedAtTheirKeys() {
        let schema = Schema.dictionary(of: .int(.range(0...9)))
        let result = schema.decodeReporting(#"{"a":1,"b c":20,"d":"x","e":2}"#)
        #expect(result.issues.map(\.path.description) == [#"$["b c"]"#, "$.d"])
        #expect(result.issues.map(\.code) == [.outOfRange, .typeMismatch])
    }

    @Test func entryCountApplies() {
        let schema = Schema.dictionary(of: .int(), .count(1...2))
        #expect(schema.decodeReporting("{}").issues.locations == ["$ too_few"])
        #expect(schema.decodeReporting(#"{"a":1,"b":2,"c":3}"#).issues[0].message.contains("3"))
    }

    @Test func encodesWithSortedKeysWhateverTheHashOrder() {
        let schema = Schema.dictionary(of: .int())
        let value = Dictionary(uniqueKeysWithValues: (0..<50).map { ("k\(49 - $0)", $0) })
        let text = schema.encode(value).encodedString(style: .compact)
        let keys = schema.encode(value).object?.keys ?? []
        #expect(keys == keys.sorted())
        #expect(text.hasPrefix(#"{"k0":49,"k1":48"#))
    }

    @Test func notAnObjectIsAMismatch() {
        #expect(Schema.dictionary(of: .int()).decodeReporting("[1]").issues.locations == ["$ type_mismatch"])
    }

    @Test func keysSwiftCannotTellApartAreRefusedNotMerged() {
        // JSON keeps "\u00e9" and "e\u0301" apart; a Swift dictionary would not.
        let result = Schema.dictionary(of: .int()).decodeReporting(#"{"\u00e9": 1, "e\u0301": 2, "plain": 3}"#)
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.duplicateKey])
        #expect(result.issues[0].source?.start.column == 15)
    }
}

@Suite("Entry points")
struct EntryPointTests {
    @Test func jsonValueInputHasPathsButNoPositions() {
        let result = Schema.array(of: .int()).decode(json(#"[1,"x"]"#))
        #expect(result.issues.count == 1)
        #expect(result.issues[0].source == nil)
        #expect(result.issues[0].description == "$[1]: expected an integer, found string \"x\"")
    }

    @Test func textInputGivesLineAndColumn() {
        let text = """
            [
              1,
              "x",
              3
            ]
            """
        let result = Schema.array(of: .int()).decodeReporting(text)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].source?.start.line == 3)
        #expect(result.issues[0].source?.start.column == 3)
        #expect(result.issues[0].description == "3:3 $[1]: expected an integer, found string \"x\"")
    }

    @Test func columnsCountScalarsNotBytes() {
        let result = Schema.array(of: .int()).decodeReporting("[\"caf\u{E9}\", 1, \"\u{1F44D}\", true]")
        #expect(result.issues.count == 3)
        #expect(result.issues[0].source?.start.column == 2)
        #expect(result.issues[1].source?.start.column == 13)
        #expect(result.issues[2].source?.start.column == 18)
    }

    @Test func throwingEntryPointReturnsTheValue() throws {
        let value = try Schema.array(of: .int()).decode("[1, 2]")
        #expect(value == [1, 2])
        let fromBytes = try Schema.array(of: .int()).decode(Array("[3]".utf8))
        #expect(fromBytes == [3])
    }

    @Test func throwingEntryPointThrowsEveryIssue() {
        do throws(ValidationFailure) {
            _ = try Schema.array(of: .int()).decode("[\"a\", 2,\n \"b\"]")
            fail("expected a failure")
        } catch {
            #expect(error.issues.count == 2)
            #expect(error.description == "1:2 $[0]: expected an integer, found string \"a\"\n2:2 $[2]: expected an integer, found string \"b\"")
        }
    }

    @Test func aStringLiteralIsTextNotAJSONString() throws {
        // `decode("...")` must mean the text overload, not the JSONValue one
        // (JSONValue is ExpressibleByStringLiteral).
        let value = try Schema.int().decode("42")
        #expect(value == 42)
    }

    @Test func malformedJSONIsOneParseErrorWithItsLocation() {
        let result = Schema.int().decodeReporting("[1,\n 2,, 3]")
        #expect(result.value == nil)
        #expect(result.issues.count == 1)
        let issue = result.issues[0]
        #expect(issue.code == .parseError)
        #expect(issue.severity == .error)
        #expect(issue.source?.start.line == 2)
        #expect(issue.source?.start.column == 4)
        #expect(issue.parameters["parseCode"] == "unexpected_character")
        #expect(issue.description == "2:4 $[2]: invalid JSON: unexpected ',' (U+002C); expected a value")
    }

    @Test func malformedJSONThrowsAValidationFailure() {
        do throws(ValidationFailure) {
            _ = try Schema.int().decode("{")
            fail("expected a failure")
        } catch {
            #expect(error.issues.map(\.code) == [.parseError])
        }
    }

    @Test func duplicateKeysAreAParseErrorFromTheStrictParser() {
        let result = Schema.dictionary(of: .int()).decodeReporting(#"{"a":1,"a":2}"#)
        #expect(result.issues.map(\.code) == [.parseError])
        #expect(result.issues[0].parameters["parseCode"] == "duplicate_key")
        // The parser's options are the caller's to loosen.
        var loose = DecodeOptions.strict
        loose.parse.duplicateKeys = .lastWins
        #expect(Schema.dictionary(of: .int()).decodeReporting(#"{"a":1,"a":2}"#, options: loose).value == ["a": 2])
    }

    @Test func lenientOptionsReadCommentsAndTrailingCommas() {
        let text = "[1, // one\n 2, /* two */\n]"
        #expect(Schema.array(of: .int()).decodeReporting(text, options: .lenient).value == [1, 2])
        #expect(Schema.array(of: .int()).decodeReporting(text).issues.map(\.code) == [.parseError])
    }

    @Test func aDocumentCarriesItsRangesIntoTheIssues() throws {
        let document = try JSONDocument(parsing: "[1, 22, \"x\"]")
        let result = Schema.array(of: .int(.range(0...9))).decode(document)
        #expect(result.issues.map(\.code) == [.outOfRange, .typeMismatch])
        #expect(result.issues[0].source?.start.column == 5)
        #expect(result.issues[0].source?.end.column == 7)
    }

    @Test func issuesAreCappedButTheDecodeStillFails() {
        var options = DecodeOptions.strict
        options.maxIssues = 5
        let text = "[" + Array(repeating: "\"x\"", count: 100).joined(separator: ",") + "]"
        let result = Schema.array(of: .int()).decodeReporting(text, options: options)
        #expect(result.value == nil)
        #expect(result.issues.count == 6)
        #expect(result.issues.last?.code == .tooManyIssues)
        #expect(result.issues.last?.severity == .warning)
        #expect(result.issues.dropLast().allSatisfy { $0.code == .typeMismatch })
    }

    @Test func decodedGetThrowsOrReturns() throws {
        let good = Schema.int().decode(json("5"))
        #expect(try good.get() == 5)
        let bad = Schema.int().decode(json("\"a\""))
        #expect(throws: ValidationFailure.self) { try bad.get() }
        #expect(bad.errors.count == 1)
        #expect(bad.warnings.isEmpty)
        #expect(bad.repairs.isEmpty)
    }

    @Test func validateFindsProblemsInSwiftValues() {
        let schema = Schema.array(of: .int(.range(0...9)))
        #expect(schema.validate([1, 2]).isEmpty)
        #expect(schema.validate([1, 20, 3]).locations == ["$[1] out_of_range"])
    }
}

@Suite("Lazy schemas")
struct LazySchemaTests {
    // A recursive shape without objects: a list whose elements are lists.
    // `Nested` is a wrapper because Swift will not take `[Self]` as `Self`.
    struct Nested: Sendable, Equatable {
        var children: [Nested]
        static let schema: Schema<[Nested]> = .array(of: Schema.lazy("Nested") { Nested.elementSchema }, .count(...3))
        static let elementSchema: Schema<Nested> = Schema<Nested>(
            node: .array(element: .lazy(name: "Nested", resolve: { Nested.elementSchema.node }), constraints: []),
            decoder: { json, state in
                guard case .array(let items) = json else {
                    state.typeMismatch(expected: "an array", found: json)
                    return nil
                }
                var children: [Nested] = []
                for (index, item) in items.enumerated() {
                    state.push(index: index)
                    if let child = Nested.elementSchema.decoder(item, &state) { children.append(child) }
                    state.pop()
                }
                return state.errorCount == 0 ? Nested(children: children) : nil
            },
            encoder: { value, state in
                .array(value.children.compactMap { Nested.elementSchema.encoder($0, &state) })
            })
    }

    @Test func aLazySchemaDelegatesToTheSchemaItNames() {
        let result = Nested.schema.decodeReporting("[[], [[], []], [[[]]]]")
        #expect(result.value?.count == 3)
        #expect(result.value?[2].children[0].children.count == 1)
        #expect(Nested.schema.decodeReporting("[[],[],[],[]]").issues.locations == ["$ too_many"])
        #expect(Nested.schema.decodeReporting("[[1]]").issues.locations == ["$[0][0] type_mismatch"])
    }

    @Test func theNodeDoesNotUnfoldTheRecursion() {
        guard case .array(let element, _) = Nested.schema.node, case .lazy(let name, let resolve) = element else {
            return fail("node")
        }
        #expect(name == "Nested")
        guard case .array(let inner, _) = resolve(), case .lazy(let innerName, _) = inner else { return fail("inner") }
        #expect(innerName == "Nested")
    }

    @Test func theDefaultNameIsTheTypeName() {
        let lazy = Schema<Nested>.lazy { Nested.elementSchema }
        guard case .lazy(let name, _) = lazy.node else { return fail("node") }
        #expect(name == "Nested")
    }
}
