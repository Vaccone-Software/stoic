import StoicJSON
import StoicTesting
import Testing

@testable import StoicSchema

private func decode(_ text: String, _ options: DecodeOptions = .strict) -> Decoded<Settings> {
    Settings.schema.decodeReporting(text, options: options)
}

@Suite("Objects with defaults: decoding")
struct ObjectDecodingTests {
    @Test func anEmptyObjectIsTheDefaultInstance() {
        let result = decode("{}")
        #expect(result.value == Settings())
        #expect(result.issues.isEmpty)
    }

    @Test func presentKeysOverrideAndMissingKeysKeepTheDefault() {
        let result = decode(#"{"scrollSpeed": 2000, "theme": "dark", "network": {"port": 9000}}"#)
        var expected = Settings()
        expected.scrollSpeed = 2000
        expected.theme = .dark
        expected.network.port = Port(clamping: 9000)
        #expect(result.value == expected)
        #expect(result.issues.isEmpty)
    }

    @Test func aFullDocumentDecodes() {
        let text = """
            {
              "scrollSpeed": 800.5,
              "theme": "light",
              "apiToken": "s3cret",
              "network": {"hosts": ["a.example", "b.example"], "port": 443, "timeoutSeconds": 5, "useTLS": false},
              "maxHistory": 7,
              "windowTitle": "Work",
              "zoom": 2.5,
              "shortcuts": {"save": "cmd-s"}
            }
            """
        let result = decode(text)
        #expect(result.issues.isEmpty)
        let value = result.value
        #expect(value?.scrollSpeed == 800.5)
        #expect(value?.network.hosts == ["a.example", "b.example"])
        #expect(value?.network.useTLS == false)
        #expect(value?.windowTitle == "Work")
        #expect(value?.zoom.value == 2.5)
        #expect(value?.shortcuts == ["save": "cmd-s"])
        #expect(value?.apiToken == "s3cret")
    }

    @Test func notAnObjectIsOneMismatch() {
        let result = decode("[1]")
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$ type_mismatch"])
        #expect(result.issues[0].message == "expected an object, found array")
    }

    @Test func nullForANonOptionalFieldIsAMismatchNotAbsence() {
        let result = decode(#"{"scrollSpeed": null}"#)
        #expect(result.value == nil)
        #expect(result.issues.locations == ["$.scrollSpeed type_mismatch"])
    }

    @Test func anOptionalFieldMayBeOmittedButNotNullUnlessNullable() {
        #expect(decode(#"{"windowTitle": "x"}"#).value?.windowTitle == "x")
        #expect(decode("{}").value?.windowTitle == nil)
        #expect(decode(#"{"windowTitle": null}"#).issues.locations == ["$.windowTitle type_mismatch"])
    }
}

@Suite("Objects with defaults: accumulation")
struct ObjectAccumulationTests {
    @Test func fiveIndependentBadFieldsAreExactlyFiveIssuesAtTheirPaths() {
        let text = """
            {
              "scrollSpeed": 99999,
              "theme": "purple",
              "maxHistory": "many",
              "network": {"port": 0, "hosts": ["ok", "", "also ok"]},
              "zoom": 9
            }
            """
        let result = decode(text)
        #expect(result.value == nil)
        #expect(
            result.issues.locations == [
                "$.scrollSpeed out_of_range",
                "$.theme not_one_of",
                "$.maxHistory type_mismatch",
                "$.network.port out_of_range",
                "$.network.hosts[1] too_short",
                "$.zoom out_of_range",
            ])
        // Issues come in reading order: `port` is written before `hosts`
        // in the file, though `hosts` is declared first.
        #expect(result.errors.count == 6)
    }

    @Test func theLocationsAreExactlyTheBrokenFieldsAndNothingElse() {
        // Mutate each field in turn and in combination: the issue paths must be
        // exactly the mutated paths.
        let mutations: [(path: String, json: String)] = [
            ("$.scrollSpeed", "\"fast\""),
            ("$.theme", "5"),
            ("$.apiToken", "7"),
            ("$.maxHistory", "-1"),
            ("$.windowTitle", "\"\""),
            ("$.zoom", "0"),
            ("$.shortcuts", "[]"),
            ("$.network", "3"),
        ]
        for mask in 1..<(1 << mutations.count) {
            let chosen = mutations.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let body = chosen.map { "\"\($0.path.dropFirst(2))\": \($0.json)" }.joined(separator: ", ")
            let result = decode("{\(body)}")
            #expect(result.value == nil, "\(body)")
            #expect(Set(result.issues.map(\.path.description)) == Set(chosen.map(\.path)), "\(body)")
            #expect(result.issues.count == chosen.count, "\(body)")
        }
    }

    @Test func nestedArrayElementsHaveFullPaths() {
        let result = decode(#"{"network": {"hosts": ["a", "b", "c", 4, "e"]}}"#)
        #expect(result.issues.locations == ["$.network.hosts[3] type_mismatch"])
        #expect(result.issues[0].path.description == "$.network.hosts[3]")
    }

    @Test func uniqueElementsAreCheckedInsideAField() {
        let result = decode(#"{"network": {"hosts": ["a", "b", "a"]}}"#)
        #expect(result.issues.locations == ["$.network.hosts[2] not_unique"])
    }

    @Test func issuesFromTextCarryLineAndColumn() {
        let text = """
            {
              "scrollSpeed": 99999,
              "network": {
                "port": 0
              }
            }
            """
        let result = decode(text)
        #expect(result.issues.count == 2)
        #expect(result.issues[0].source?.start.line == 2)
        #expect(result.issues[0].source?.start.column == 18)
        #expect(result.issues[1].source?.start.line == 4)
        #expect(result.issues[1].source?.start.column == 13)
        #expect(
            result.issues[0].description
                == "2:18 $.scrollSpeed: 99999 is out of range, expected a number between 200 and 4000")
        #expect(
            result.issues[1].description
                == "4:13 $.network.port: 0 is out of range, expected a number between 1 and 65535")
    }

    @Test func failureDescriptionIsOneIssuePerLine() {
        do throws(ValidationFailure) {
            _ = try Settings.schema.decode(#"{"scrollSpeed": 1, "theme": "x", "maxHistory": -5}"#) { _ in }
            fail("expected a failure")
        } catch {
            let lines = error.description.split(separator: "\n").map(String.init)
            #expect(lines.count == 3)
            #expect(lines[0].hasPrefix("1:17 $.scrollSpeed: 1 is out of range"))
            #expect(lines[1].hasPrefix("1:29 $.theme: \"x\" is not allowed"))
            #expect(lines[2].hasPrefix("1:48 $.maxHistory: -5 is out of range"))
        }
    }
}

@Suite("Objects with defaults: unknown keys and did-you-mean")
struct UnknownKeyTests {
    @Test func aTypoIsAWarningWithTheRightSuggestionAndTheDocumentStillDecodes() {
        let result = decode(#"{"scrolSpeed": 2000}"#)
        #expect(result.value == Settings())  // the typo'd key did nothing
        #expect(result.issues.count == 1)
        let issue = result.issues[0]
        #expect(issue.severity == .warning)
        #expect(issue.code == .unknownKey)
        #expect(issue.path.description == "$.scrolSpeed")
        #expect(issue.suggestions == ["scrollSpeed"])
        #expect(issue.description == "1:2 $.scrolSpeed: warning: unknown key `scrolSpeed` (did you mean `scrollSpeed`?)")
    }

    @Test func aTranspositionIsFound() {
        let result = decode(#"{"thmee": "dark", "netwrok": {}, "scrollSpede": 1}"#)
        #expect(result.issues.map(\.suggestions) == [["theme"], ["network"], ["scrollSpeed"]])
    }

    @Test func nothingIsSuggestedWhenTheKeyIsTooFar() {
        let result = decode(#"{"completelyDifferent": 1, "x": 2}"#)
        #expect(result.issues.count == 2)
        #expect(result.issues.allSatisfy { $0.suggestions.isEmpty })
        #expect(result.issues[0].description == "1:2 $.completelyDifferent: warning: unknown key `completelyDifferent`")
    }

    @Test func nestedObjectsSuggestTheirOwnKeys() {
        let result = decode(#"{"network": {"prot": 80, "useTls": true}}"#)
        // `useTls` differs from `useTLS` only in case: an alias, not unknown.
        // Issues are in reading order, and `prot` comes first in the text.
        #expect(result.issues.map(\.code) == [.unknownKey, .deprecatedKey])
        #expect(result.issues[0].path.description == "$.network.prot")
        #expect(result.issues[0].suggestions == ["port"])
    }

    @Test func rejectMakesItAnError() {
        let strict = Schema.object(Network.self, default: Network(), unknownKeys: .reject) {
            Field("port", \.port, Port.schema)
        }
        let result = strict.decodeReporting(#"{"prot": 80}"#)
        #expect(result.value == nil)
        #expect(result.issues.map(\.severity) == [.error])
        #expect(result.issues[0].suggestions == ["port"])
    }

    @Test func ignoreIsSilent() {
        let quiet = Schema.object(Network.self, default: Network(), unknownKeys: .ignore) {
            Field("port", \.port, Port.schema)
        }
        let result = quiet.decodeReporting(#"{"prot": 80, "port": 81}"#)
        #expect(result.issues.isEmpty)
        #expect(result.value?.port.value == 81)
    }

    @Test func suggestionsListAtMostThreeInDeclarationOrder() {
        enum Digits: Sendable { case x }
        struct Wide: Sendable {
            var a1 = 0, a2 = 0, a3 = 0, a4 = 0, a5 = 0
        }
        let wide = Schema.object(Wide.self, default: Wide()) {
            Field("abcd1", \.a1, .int())
            Field("abcd2", \.a2, .int())
            Field("abcd3", \.a3, .int())
            Field("abcd4", \.a4, .int())
            Field("abcd5", \.a5, .int())
        }
        let result = wide.decodeReporting(#"{"abcd": 1}"#)
        #expect(result.issues[0].suggestions == ["abcd1", "abcd2", "abcd3"])
        #expect(result.issues[0].description.hasSuffix("(did you mean `abcd1`, `abcd2`, or `abcd3`?)"))
    }

    @Test func suggestionsAreTheSameOnEveryRun() {
        let first = decode(#"{"thme": 1}"#).issues[0].suggestions
        for _ in 0..<10 { #expect(decode(#"{"thme": 1}"#).issues[0].suggestions == first) }
    }

    @Test func keysThatDifferOnlyByNormalisationAreNotTheSameKey() {
        // "cafe\u{301}" is a different key from "caf\u{E9}" in JSON. It is
        // accepted as the field only the way any other respelling is, with a
        // warning, and never silently merged with an exact key.
        struct Cafe: Sendable { var name = "x" }
        let schema = Schema.object(Cafe.self, default: Cafe(), unknownKeys: .reject) {
            Field("caf\u{E9}", \.name, .string())
        }
        #expect(schema.decodeReporting("{\"caf\u{E9}\": \"a\"}").issues.isEmpty)
        let respelled = schema.decodeReporting("{\"cafe\u{301}\": \"a\"}")
        #expect(respelled.value?.name == "a")
        #expect(respelled.issues.map(\.code) == [.deprecatedKey])
        let both = schema.decodeReporting("{\"caf\u{E9}\": \"a\", \"cafe\u{301}\": \"b\"}")
        #expect(both.value == nil)
        #expect(both.issues.map(\.code) == [.duplicateKey])
    }
}

@Suite("Objects with defaults: aliases and deprecation")
struct AliasTests {
    @Test(.failureMode("design/06", "a key uses the snake_case spelling")) func snakeCaseIsAnAliasNotAnUnknownKey() {
        let result = decode(#"{"scroll_speed": 2000}"#)
        #expect(result.value?.scrollSpeed == 2000)
        #expect(result.issues.count == 1)
        let issue = result.issues[0]
        #expect(issue.severity == .warning)
        #expect(issue.code == .deprecatedKey)
        #expect(issue.path.description == "$.scrollSpeed")
        #expect(issue.suggestions == ["scrollSpeed"])
        #expect(issue.source?.start.column == 2)  // the key as written
        #expect(
            issue.description
                == "1:2 $.scrollSpeed: warning: `scroll_speed` is a deprecated spelling of `scrollSpeed` (did you mean `scrollSpeed`?)")
    }

    @Test func caseAndSeparatorVariantsAreAccepted() {
        for spelling in ["ScrollSpeed", "scrollspeed", "scroll-speed", "SCROLL_SPEED", "Scroll Speed"] {
            let result = decode("{\"\(spelling)\": 2000}")
            #expect(result.value?.scrollSpeed == 2000, "\(spelling)")
            #expect(result.issues.map(\.code) == [.deprecatedKey], "\(spelling)")
        }
    }

    @Test func anExplicitAliasIsAccepted() {
        let result = decode(#"{"network": {"servers": ["a.example"]}}"#)
        #expect(result.value?.network.hosts == ["a.example"])
        #expect(result.issues.map(\.code) == [.deprecatedKey])
        #expect(result.issues[0].path.description == "$.network.hosts")
        #expect(result.issues[0].message == "`servers` is a deprecated spelling of `hosts`")
    }

    @Test func errorsUnderAnAliasAreReportedAtTheCanonicalPathButPointAtTheText() {
        let result = decode(#"{"network": {"servers": ["a", ""]}}"#)
        let error = result.errors[0]
        #expect(error.path.description == "$.network.hosts[1]")
        #expect(error.source?.start.column == 31)  // the empty string in the file
    }

    @Test func twoSpellingsOfOneFieldAreADuplicateNotAGuess() {
        let result = decode(#"{"scrollSpeed": 1000, "scroll_speed": 2000}"#)
        #expect(result.value == nil)
        #expect(result.issues.map(\.code) == [.duplicateKey])
        #expect(result.issues[0].path.description == "$.scroll_speed")
        #expect(result.issues[0].message == "`scroll_speed` repeats `scrollSpeed`, which names the same field")
        let twoAliases = decode(#"{"network": {"servers": [], "HOSTS": []}}"#)
        #expect(twoAliases.errors.map(\.code) == [.duplicateKey])
    }

    @Test func aFieldIsNotStolenFromItsOwnExactKey() {
        // `useTLS` and `useTls` normalise alike; the exact one wins its field
        // and the other is a duplicate, not an unknown key.
        let result = decode(#"{"network": {"useTLS": false, "useTls": true}}"#)
        #expect(result.issues.map(\.code) == [.duplicateKey])
    }

    @Test func deprecatedFieldsWarnWhenUsed() {
        let result = decode(#"{"legacyMode": true}"#)
        #expect(result.value?.legacyMode == true)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].code == .deprecatedKey)
        #expect(result.issues[0].severity == .warning)
        #expect(result.issues[0].message == "`legacyMode` is deprecated: Use `theme` instead.")
        #expect(decode("{}").issues.isEmpty)
    }
}

@Suite("Objects with defaults: lenient repair")
struct LenientRepairTests {
    @Test func aBadFieldFallsBackToItsDefaultWithARepairedIssue() {
        let result = decode(#"{"scrollSpeed": 99999, "theme": "dark"}"#, .lenient)
        #expect(result.value?.scrollSpeed == 1200)
        #expect(result.value?.theme == .dark)
        #expect(result.issues.count == 1)
        let issue = result.issues[0]
        #expect(issue.severity == .repaired)
        #expect(issue.code == .outOfRange)
        #expect(issue.path.description == "$.scrollSpeed")
        #expect(
            issue.description
                == "1:17 $.scrollSpeed: repaired: 99999 is out of range, expected a number between 200 and 4000; used the default 1200")
        #expect(result.errors.isEmpty)
    }

    @Test func everyBadFieldIsRepairedIndependently() {
        let result = decode(
            #"{"scrollSpeed": "x", "theme": 3, "network": {"port": 0, "hosts": ["a", ""]}, "maxHistory": 5}"#, .lenient)
        #expect(result.value?.maxHistory == 5)
        #expect(result.value?.scrollSpeed == 1200)
        #expect(result.value?.network == Network())
        #expect(result.issues.allSatisfy { $0.severity == .repaired })
        #expect(
            result.issues.map(\.path.description)
                == ["$.scrollSpeed", "$.theme", "$.network.port", "$.network.hosts[1]"])
    }

    @Test func repairHappensAtTheInnermostFieldWithADefault() {
        // The port is replaced, not the whole network.
        let result = decode(#"{"network": {"port": 0, "useTLS": false}}"#, .lenient)
        #expect(result.value?.network.useTLS == false)
        #expect(result.value?.network.port.value == 8080)
    }

    @Test func aWholeBadArrayFallsBackToTheFieldsDefault() {
        let result = decode(#"{"network": {"hosts": ["a", 5, "c"]}}"#, .lenient)
        #expect(result.value?.network.hosts == ["localhost"])
        #expect(result.issues.map(\.severity) == [.repaired])
        #expect(result.issues[0].path.description == "$.network.hosts[1]")
    }

    @Test func aRejectedUnknownKeyIsIgnoredAndReported() {
        let strict = Schema.object(Network.self, default: Network(), unknownKeys: .reject) {
            Field("port", \.port, Port.schema)
        }
        let result = strict.decodeReporting(#"{"prot": 80}"#, options: .lenient)
        #expect(result.value == Network())
        #expect(result.issues.map(\.severity) == [.repaired])
        #expect(result.issues[0].message == "unknown key `prot`; ignored it")
    }

    @Test func aRootThatIsNotAnObjectCannotBeRepaired() {
        let result = decode("[]", .lenient)
        #expect(result.value == nil)
        #expect(result.errors.count == 1)
    }

    @Test func lenientReadsCommentsAndTrailingCommas() {
        let text = """
            {
              // louder
              "scrollSpeed": 3000, /* px/s */
            }
            """
        let result = decode(text, .lenient)
        #expect(result.value?.scrollSpeed == 3000)
        #expect(result.issues.isEmpty)
        #expect(decode(text).issues.map(\.code) == [.parseError])
    }

    @Test func strictDoesNotRepair() {
        let result = decode(#"{"scrollSpeed": 99999}"#)
        #expect(result.value == nil)
        #expect(result.issues.map(\.severity) == [.error])
    }

    @Test func warningsInsideARepairedFieldAreKept() {
        // The deprecated spelling's warning was raised before the field was
        // read, and stays a warning.
        let result = decode(#"{"scroll_speed": 99999}"#, .lenient)
        #expect(result.issues.map(\.severity) == [.warning, .repaired])
        #expect(result.value?.scrollSpeed == 1200)
    }
}

@Suite("Secrets")
struct SecretTests {
    @Test func aSecretIsNeverEchoedInAnIssue() {
        let result = decode(#"{"apiToken": 12345}"#)
        let issue = result.issues[0]
        #expect(issue.code == .typeMismatch)
        #expect(issue.actual == nil)
        #expect(issue.suggestions.isEmpty)
        #expect(!issue.description.contains("12345"))
        #expect(issue.description == "1:14 $.apiToken: expected a string, found number")
    }

    @Test func aConstraintOnASecretDoesNotEchoItEither() {
        let long = String(repeating: "k", count: 200)
        let result = decode("{\"apiToken\": \"\(long)\"}")
        #expect(result.issues.map(\.code) == [.tooLong])
        #expect(result.issues[0].actual == nil)
        #expect(!result.issues[0].description.contains("kkkk"))
        #expect(!ValidationFailure(issues: result.issues).description.contains("kkkk"))
    }

    @Test func aSecretStringIsNotSuggestedFromItsDigits() {
        let result = decode(#"{"apiToken": "x"}"#)
        #expect(result.issues.isEmpty)
        // A number where a string belongs would otherwise suggest `"12345"`.
        #expect(decode(#"{"apiToken": 12345}"#).issues[0].suggestions.isEmpty)
    }

    @Test func aRepairedSecretDoesNotShowItsDefault() {
        struct Vault: Sendable, Equatable { var key = "default-secret-value" }
        let schema = Schema.object(Vault.self, default: Vault()) {
            Field("key", \.key, .string(.length(...5)), secret: true)
        }
        let result = schema.decodeReporting(#"{"key": "much too long"}"#, options: .lenient)
        #expect(result.value == Vault())
        #expect(result.issues[0].severity == .repaired)
        #expect(!result.issues[0].description.contains("default-secret-value"))
        #expect(!result.issues[0].description.contains("much too long"))
        #expect(result.issues[0].message.hasSuffix("; used the default"))
    }

    @Test func aSecretEnumerationDoesNotLeakNearbyValues() {
        struct Gate: Sendable, Equatable { var level = Theme.light }
        let schema = Schema.object(Gate.self, default: Gate()) {
            Field("level", \.level, .enumeration(Theme.self), secret: true)
        }
        let result = schema.decodeReporting(#"{"level": "dark "}"#)
        #expect(result.issues[0].suggestions.isEmpty)
        #expect(result.issues[0].actual == nil)
    }

    @Test func nestedValuesInsideASecretFieldAreAlsoRedacted() {
        struct Keys: Sendable, Equatable { var tokens: [String] = [] }
        let schema = Schema.object(Keys.self, default: Keys()) {
            Field("tokens", \.tokens, .array(of: .string(.length(3...6))), secret: true)
        }
        let result = schema.decodeReporting(#"{"tokens": ["abc", "supersecretvalue", 7]}"#)
        #expect(result.issues.count == 2)
        #expect(result.issues.allSatisfy { $0.actual == nil && $0.suggestions.isEmpty })
        #expect(!ValidationFailure(issues: result.issues).description.contains("supersecret"))
    }

    @Test func nodeMarksSecretsAndHidesTheirDefaults() {
        guard case .object(let node) = Settings.schema.node,
            let token = node.fields.first(where: { $0.key == "apiToken" })
        else { return fail("node") }
        #expect(token.isSecret)
        #expect(token.hasDefault)
        #expect(token.defaultValue == nil)
        #expect(node.fields.first(where: { $0.key == "theme" })?.defaultValue == "system")
    }
}

@Suite("Objects with defaults: declaration")
struct ObjectDeclarationTests {
    @Test func nodeCarriesEverythingTheExporterNeeds() {
        guard case .object(let node) = Settings.schema.node else { return fail("node") }
        #expect(node.name == "Settings")
        #expect(node.doc == "Application settings.")
        #expect(node.unknownKeys == .warn)
        #expect(
            node.fields.map(\.key) == [
                "scrollSpeed", "theme", "apiToken", "network", "maxHistory", "windowTitle", "zoom", "shortcuts",
                "legacyMode",
            ])
        let speed = node.fields[0]
        #expect(speed.doc == "Pixels per second.")
        #expect(speed.unit == "px/s")
        #expect(speed.defaultValue == 1200)
        #expect(!speed.isRequired)
        #expect(speed.node.constraints == [.range(200...4000)])
        #expect(node.fields[8].deprecation?.message == "Use `theme` instead.")
        let network = node.fields[3]
        guard case .object(let networkNode) = network.node else { return fail("network node") }
        #expect(networkNode.fields[0].aliases == ["servers"])
        #expect(networkNode.fields[0].defaultValue == ["localhost"])
    }

    @Test func theDefaultsComeFromTheDefaultInstanceAlone() {
        struct Tuned: Sendable, Equatable { var level = 7 }
        let schema = Schema.object(Tuned.self, default: Tuned(level: 9)) {
            Field("level", \.level, .int())
        }
        #expect(schema.decodeReporting("{}").value == Tuned(level: 9))
        guard case .object(let node) = schema.node else { return fail("node") }
        #expect(node.fields[0].defaultValue == 9)
    }

    @Test func fieldsMayBeConditionalOrGeneratedInTheBuilder() {
        struct Flags: Sendable, Equatable { var a = false, b = false }
        let includeB = true
        let schema = Schema.object(Flags.self, default: Flags()) {
            Field("a", \.a, .bool)
            if includeB { Field("b", \.b, .bool) }
        }
        guard case .object(let node) = schema.node else { return fail("node") }
        #expect(node.fields.map(\.key) == ["a", "b"])
    }
}
