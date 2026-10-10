import StoicJSON
import Testing

@testable import StoicSchema

private func sample() -> Settings {
    var settings = Settings()
    settings.scrollSpeed = 2400.5
    settings.theme = .dark
    settings.apiToken = "tok-123"
    settings.network.hosts = ["a.example", "b.example"]
    settings.network.port = Port(clamping: 9000)
    settings.network.useTLS = false
    settings.maxHistory = 500
    settings.windowTitle = "Work"
    settings.zoom = Zoom(clamping: 1.5)
    settings.shortcuts = ["save": "cmd-s", "open": "cmd-o"]
    return settings
}

@Suite("Full encoding")
struct FullEncodingTests {
    @Test func writesEveryFieldInDeclarationOrder() {
        let encoded = Settings.schema.encode(Settings())
        #expect(
            encoded.object?.keys == [
                "scrollSpeed", "theme", "apiToken", "network", "maxHistory", "zoom", "shortcuts",
            ])
        // `legacyMode` is deprecated and at its default: not written.
        // `windowTitle` is an optional that is nil and not nullable: no key.
        #expect(encoded.object?["windowTitle"] == nil)
        #expect(encoded.object?["network"]?.object?.keys == ["hosts", "port", "timeoutSeconds", "useTLS"])
    }

    @Test func theTextIsExactlyWhatTheDeclarationSays() {
        let text = Settings.schema.encode(Settings()).encodedString(style: .compact)
        #expect(
            text
                == #"{"scrollSpeed":1200,"theme":"system","apiToken":"","network":{"hosts":["localhost"],"port":8080,"timeoutSeconds":30,"useTLS":true},"maxHistory":100,"zoom":1,"shortcuts":{}}"#)
    }

    @Test func fullIncludesSecretsUnlessAskedNotTo() {
        let settings = sample()
        #expect(Settings.schema.encode(settings, style: .full).object?["apiToken"] == "tok-123")
        #expect(Settings.schema.encode(settings, style: .fullWithoutSecrets).object?["apiToken"] == nil)
    }

    @Test func roundTripsEverySample() {
        for settings in [Settings(), sample()] {
            let text = Settings.schema.encode(settings).encodedString()
            let back = Settings.schema.decodeReporting(text)
            #expect(back.value == settings)
            #expect(back.issues.isEmpty)
        }
    }

    @Test func aDeprecatedFieldIsWrittenOnlyWhenItCarriesAValue() {
        var settings = Settings()
        settings.legacyMode = true
        #expect(Settings.schema.encode(settings).object?["legacyMode"] == true)
        settings.legacyMode = false
        #expect(Settings.schema.encode(settings).object?["legacyMode"] == nil)
    }

    @Test func canonicalTextIsStable() {
        let first = Settings.schema.encode(sample()).encodedString(style: .canonical)
        let second = Settings.schema.encode(sample()).encodedString(style: .canonical)
        #expect(first == second)
        let decoded = Settings.schema.decodeReporting(first).value
        #expect(decoded.map { Settings.schema.encode($0).encodedString(style: .canonical) } == first)
    }
}

@Suite("Sparse encoding")
struct SparseEncodingTests {
    @Test func theDefaultInstanceIsAnEmptyObject() {
        #expect(Settings.schema.encode(Settings(), style: .sparse) == [:])
    }

    @Test func onlyChangedFieldsAreWritten() {
        var settings = Settings()
        settings.theme = .dark
        settings.network.port = Port(clamping: 9000)
        let text = Settings.schema.encode(settings, style: .sparse).encodedString(style: .compact)
        #expect(text == #"{"theme":"dark","network":{"port":9000}}"#)
    }

    @Test func aFieldChangedBackToItsDefaultDisappears() {
        var settings = Settings()
        settings.maxHistory = 5
        settings.maxHistory = 100
        #expect(Settings.schema.encode(settings, style: .sparse) == [:])
    }

    @Test func secretsAreLeftOutUnlessAskedFor() {
        var settings = Settings()
        settings.apiToken = "tok-123"
        #expect(Settings.schema.encode(settings, style: .sparse) == [:])
        let included = Settings.schema.encode(settings, style: .sparse(includeSecrets: true))
        #expect(included == ["apiToken": "tok-123"])
        // A secret at its default is omitted even when asked for.
        #expect(Settings.schema.encode(Settings(), style: .sparse(includeSecrets: true)) == [:])
    }

    @Test func aNestedObjectIsWrittenRelativeToItsOwnDefault() {
        var settings = Settings()
        settings.network.hosts = ["localhost", "backup"]
        let encoded = Settings.schema.encode(settings, style: .sparse)
        #expect(encoded == ["network": ["hosts": ["localhost", "backup"]]])
    }

    @Test func collectionsAreWrittenWholeOrNotAtAll() {
        var settings = Settings()
        settings.shortcuts = ["a": "b"]
        #expect(Settings.schema.encode(settings, style: .sparse) == ["shortcuts": ["a": "b"]])
    }

    @Test func aFieldWhoseDefaultIsNotNilCanBeNilledOnlyWithNull() {
        struct Titled: Sendable, Equatable { var title: String? = "Untitled" }
        let plain = Schema.object(Titled.self, default: Titled()) {
            Field("title", \.title, .optional(.string()))
        }
        let nullable = Schema.object(Titled.self, default: Titled()) {
            Field("title", \.title, .optional(.string(), nullable: true))
        }
        let cleared = Titled(title: nil)
        // Without a null spelling, nil is unwritable: the key is left out and
        // so the default would come back. The nullable schema round-trips it.
        #expect(plain.encode(cleared, style: .sparse) == [:])
        #expect(nullable.encode(cleared, style: .sparse) == ["title": .null])
        #expect(nullable.decodeReporting(nullable.encode(cleared, style: .sparse).encodedString()).value == cleared)
        #expect(nullable.encode(Titled(), style: .sparse) == [:])
    }

    @Test func sparseIsAFixedPointOfDecodeThenEncode() {
        var variants = [Settings(), sample()]
        var onlyNested = Settings()
        onlyNested.network.timeoutSeconds = 5
        variants.append(onlyNested)
        var withSecret = Settings()
        withSecret.apiToken = "z"
        variants.append(withSecret)
        for style in [EncodeStyle.sparse, .sparse(includeSecrets: true)] {
            for settings in variants {
                let once = Settings.schema.encode(settings, style: style)
                let decoded = Settings.schema.decodeReporting(once.encodedString()).value
                #expect(decoded != nil)
                let twice = decoded.map { Settings.schema.encode($0, style: style) }
                #expect(twice == once)
            }
        }
    }

    @Test func sparseRoundTripsWhenSecretsAreIncluded() {
        let settings = sample()
        let encoded = Settings.schema.encode(settings, style: .sparse(includeSecrets: true))
        #expect(Settings.schema.decodeReporting(encoded.encodedString()).value == settings)
    }

    @Test func sparseWithoutSecretsLosesOnlyTheSecrets() {
        let settings = sample()
        let encoded = Settings.schema.encode(settings, style: .sparse)
        var expected = settings
        expected.apiToken = ""
        #expect(Settings.schema.decodeReporting(encoded.encodedString()).value == expected)
    }

    @Test func aNestedDefaultThatDiffersFromTheNestedTypesDefaultStillRoundTrips() {
        struct Outer: Sendable, Equatable {
            var network = Network(hosts: ["custom"], port: Port(clamping: 9999), timeoutSeconds: 1, useTLS: false)
        }
        let schema = Schema.object(Outer.self, default: Outer()) {
            Field("network", \.network, Network.schema)
        }
        // Equal to the outer default: omitted, and the outer default returns.
        #expect(schema.encode(Outer(), style: .sparse) == [:])
        #expect(schema.decodeReporting("{}").value == Outer())
        // Equal to Network()'s own default but not to the outer default: must
        // be written, as an object relative to Network(), here empty.
        var reset = Outer()
        reset.network = Network()
        let encoded = schema.encode(reset, style: .sparse)
        #expect(encoded == ["network": [:]])
        #expect(schema.decodeReporting(encoded.encodedString()).value == reset)
        // Partially changed from the outer default.
        var partial = Outer()
        partial.network.port = Port(clamping: 1)
        let partialEncoded = schema.encode(partial, style: .sparse)
        let decoded = schema.decodeReporting(partialEncoded.encodedString()).value
        #expect(schema.encode(decoded ?? Outer(), style: .sparse) == partialEncoded)
    }

    @Test func validateFindsAValueTheSchemaWouldNotHaveDecoded() {
        var settings = Settings()
        #expect(Settings.schema.validate(settings).isEmpty)
        settings.scrollSpeed = 10
        settings.network.hosts = ["a", "a"]
        settings.apiToken = String(repeating: "x", count: 500)
        let issues = Settings.schema.validate(settings)
        #expect(issues.locations == ["$.scrollSpeed out_of_range", "$.apiToken too_long", "$.network.hosts[1] not_unique"])
        #expect(issues.allSatisfy { !$0.description.contains("xxxx") })
    }
}
