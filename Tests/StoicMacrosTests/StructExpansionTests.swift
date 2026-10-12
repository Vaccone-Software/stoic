#if STOIC_MACROS
import Testing

@Suite("@Schema on a struct: the expansion")
struct StructExpansionTests {
    @Test func aStructBecomesAnObjectWithADefaultInstance() {
        expand(
            """
            /// Application settings.
            @Schema
            struct Settings {
                /// Pixels per second.
                @Unit("px/s") var scrollSpeed: Double = 1000
                var theme: Theme = .dark
                var network = Network()
                var hosts: [String] = []
                var title: String? = nil
            }
            """,
            to: """
                /// Application settings.
                struct Settings {
                    /// Pixels per second.
                    var scrollSpeed: Double = 1000
                    var theme: Theme = .dark
                    var network = Network()
                    var hosts: [String] = []
                    var title: String? = nil

                    static let schema: StoicSchema::Schema<Settings> = StoicSchema::Schema.object(Settings.self, default: Settings(), doc: "Application settings.") {
                        StoicSchema::Field("scrollSpeed", \\.scrollSpeed, .double(), doc: "Pixels per second.", unit: "px/s")
                        StoicSchema::Field("theme", \\.theme, Theme.schema)
                        StoicSchema::Field("network", \\.network, Network.schema)
                        StoicSchema::Field("hosts", \\.hosts, .array(of: .string()))
                        StoicSchema::Field("title", \\.title, .optional(.string()))
                    }
                }

                extension Settings: StoicSchema::Schematic {
                }
                """)
    }

    @Test func markersChangeTheField() {
        expand(
            """
            @Schema
            struct Account {
                @Key("api_token") @Secret var apiToken: String = ""
                @Aliases("old_name", "name_v1") @Deprecated("Use `title`.") var name = ""
                @Nullable var note: String? = "none"
                @Ignored var cache: [String: Int] = [:]
            }
            """,
            to: """
                struct Account {
                    var apiToken: String = ""
                    var name = ""
                    var note: String? = "none"
                    var cache: [String: Int] = [:]

                    static let schema: StoicSchema::Schema<Account> = StoicSchema::Schema.object(Account.self, default: Account()) {
                        StoicSchema::Field("api_token", \\.apiToken, .string(), secret: true)
                        StoicSchema::Field("name", \\.name, .string(), aliases: ["old_name", "name_v1"], deprecated: "Use `title`.")
                        StoicSchema::Field("note", \\.note, .optional(.string(), nullable: true))
                    }
                }

                extension Account: StoicSchema::Schematic {
                }
                """)
    }

    @Test func foundationTypesAreFieldsAndAFormatAttributeChoosesTheirSpelling() {
        expand(
            """
            @Schema
            struct Event {
                var id = UUID()
                var created: Date = Date()
                @DateFormat(.epochSeconds) var seen: Date = Date()
                @DateFormat(.epochMilliseconds) var clicks: [Date?] = []
                var home: URL = URL(string: "https://example.com")!
                @URLFormat(.relative) var link: URL? = nil
                var blob: Data = Data()
                @DataFormat(.base64url) var token: [String: Data] = [:]
                @Range(0...100) @MultipleOf(0.5) var discount: Decimal = 0
                var prices: [Decimal] = []
            }
            """,
            to: """
                struct Event {
                    var id = UUID()
                    var created: Date = Date()
                    var seen: Date = Date()
                    var clicks: [Date?] = []
                    var home: URL = URL(string: "https://example.com")!
                    var link: URL? = nil
                    var blob: Data = Data()
                    var token: [String: Data] = [:]
                    var discount: Decimal = 0
                    var prices: [Decimal] = []

                    static let schema: StoicSchema::Schema<Event> = StoicSchema::Schema.object(Event.self, default: Event()) {
                        StoicSchema::Field("id", \\.id, .uuid)
                        StoicSchema::Field("created", \\.created, .date())
                        StoicSchema::Field("seen", \\.seen, .date(.epochSeconds))
                        StoicSchema::Field("clicks", \\.clicks, .array(of: .optional(.date(.epochMilliseconds))))
                        StoicSchema::Field("home", \\.home, .url())
                        StoicSchema::Field("link", \\.link, .optional(.url(.relative)))
                        StoicSchema::Field("blob", \\.blob, .data())
                        StoicSchema::Field("token", \\.token, .dictionary(of: .data(.base64url)))
                        StoicSchema::Field("discount", \\.discount, .decimal(.range(0 ... 100), .multipleOf(0.5)))
                        StoicSchema::Field("prices", \\.prices, .array(of: .decimal()))
                    }
                }

                extension Event: StoicSchema::Schematic {
                }
                """)
    }

    @Test func publicTypesGetPublicSchemas() {
        expand(
            """
            @Schema
            public struct Account {
                public var id: Int64 = 0
                var tags: [String] = []
            }
            """,
            to: """
                public struct Account {
                    public var id: Int64 = 0
                    var tags: [String] = []

                    public static let schema: StoicSchema::Schema<Account> = StoicSchema::Schema.object(Account.self, default: Account()) {
                        StoicSchema::Field("id", \\.id, .int64())
                        StoicSchema::Field("tags", \\.tags, .array(of: .string()))
                    }
                }

                extension Account: StoicSchema::Schematic {
                }
                """)
    }

    @Test func typesAreReadAsWritten() {
        expand(
            """
            @Schema
            struct Mixed {
                var a: Int32 = 0
                var b: UInt64 = 0
                var c: Int64 = 0
                var d: [[Int]] = []
                var e: Optional<[String: Double]> = nil
                var f: Secret<String>? = nil
                var g: Port = Port(clamping: 80)
                var h: Swift.String = ""
                var i: JSONValue = .null
                var `default` = 1.5
                var j = -3
                var k = Inner.Deep()
                var l: Refined<IntRange<1, 9>> = try! Refined(3)
                var m: Mixed? = nil
                var n: [Mixed] = []
            }
            """,
            to: """
                struct Mixed {
                    var a: Int32 = 0
                    var b: UInt64 = 0
                    var c: Int64 = 0
                    var d: [[Int]] = []
                    var e: Optional<[String: Double]> = nil
                    var f: Secret<String>? = nil
                    var g: Port = Port(clamping: 80)
                    var h: Swift.String = ""
                    var i: JSONValue = .null
                    var `default` = 1.5
                    var j = -3
                    var k = Inner.Deep()
                    var l: Refined<IntRange<1, 9>> = try! Refined(3)
                    var m: Mixed? = nil
                    var n: [Mixed] = []

                    static let schema: StoicSchema::Schema<Mixed> = StoicSchema::Schema.object(Mixed.self, default: Mixed()) {
                        StoicSchema::Field("a", \\.a, .integer(Int32.self))
                        StoicSchema::Field("b", \\.b, .uint64())
                        StoicSchema::Field("c", \\.c, .int64())
                        StoicSchema::Field("d", \\.d, .array(of: .array(of: .int())))
                        StoicSchema::Field("e", \\.e, .optional(.dictionary(of: .double())))
                        StoicSchema::Field("f", \\.f, .optional(.transform(base: .string(), decode: {
                                        Secret($0)
                                    }, encode: {
                                        $0.reveal()
                                    }, describe: "a secret value")), secret: true)
                        StoicSchema::Field("g", \\.g, Port.schema)
                        StoicSchema::Field("h", \\.h, .string())
                        StoicSchema::Field("i", \\.i, .json())
                        StoicSchema::Field("default", \\.`default`, .double())
                        StoicSchema::Field("j", \\.j, .int())
                        StoicSchema::Field("k", \\.k, Inner.Deep.schema)
                        StoicSchema::Field("l", \\.l, Refined<IntRange<1, 9>>.schema)
                        StoicSchema::Field("m", \\.m, .optional(.lazy {
                                    Mixed.schema
                                }))
                        StoicSchema::Field("n", \\.n, .array(of: .lazy {
                                    Mixed.schema
                                }))
                    }
                }

                extension Mixed: StoicSchema::Schematic {
                }
                """)
    }

    @Test func aPropertyWithoutADefaultIsRequired() {
        expand(
            """
            @Schema
            struct Account {
                /// The number.
                var id: Int
                @Key("created_at") var createdAt: Date
                var email: String?
                @Nullable var phone: String?
                var plan: String = "free"
                var friends: [Account] = []
                @Ignored var cache: [String: Int] = [:]
                @PreserveUnknownKeys var extra: JSONObject = [:]
            }
            """,
            to: """
                struct Account {
                    /// The number.
                    var id: Int
                    var createdAt: Date
                    var email: String?
                    var phone: String?
                    var plan: String = "free"
                    var friends: [Account] = []
                    var cache: [String: Int] = [:]
                    var extra: JSONObject = [:]

                    static let schema: StoicSchema::Schema<Account> = StoicSchema::Schema.object(Account.self) { f in
                        let slot0 = f.field("id", \\.id, .int(), doc: "The number.")
                        let slot1 = f.field("created_at", \\.createdAt, .date())
                        let slot2 = f.field("email", \\.email, .optional(.string(), nullable: true))
                        let slot3 = f.field("phone", \\.phone, .optional(.string(), nullable: true))
                        let slot4 = f.field("plan", \\.plan, .string(), default: "free")
                        let slot5 = f.field("friends", \\.friends, .array(of: .lazy {
                                    Account.schema
                                }), default: [])
                        let preserved = f.unknownKeys(\\Account.extra)
                        return f.build { v in
                            Account(id: v[slot0], createdAt: v[slot1], email: v[slot2], phone: v[slot3], plan: v[slot4], friends: v[slot5], extra: v[preserved])
                        }
                    }
                }

                extension Account: StoicSchema::Schematic {
                }
                """)
    }

    @Test func constantsAreFilledByTheInitialiser() {
        expand(
            """
            @Schema
            struct Frozen {
                let id: Int
                let tags: [String]
            }
            """,
            to: """
                struct Frozen {
                    let id: Int
                    let tags: [String]

                    static let schema: StoicSchema::Schema<Frozen> = StoicSchema::Schema.object(Frozen.self) { f in
                        let slot0 = f.field("id", \\.id, .int())
                        let slot1 = f.field("tags", \\.tags, .array(of: .string()))
                        return f.build { v in
                            Frozen(id: v[slot0], tags: v[slot1])
                        }
                    }
                }

                extension Frozen: StoicSchema::Schematic {
                }
                """)
    }

    @Test func lossyArraysDropTheirBadElements() {
        expand(
            """
            @Schema
            struct Page {
                @Lossy @Range(0...9) @Count(...4) var ids: [Int] = []
                @Lossy var maybe: [[String]]? = nil
            }
            """,
            to: """
                struct Page {
                    var ids: [Int] = []
                    var maybe: [[String]]? = nil

                    static let schema: StoicSchema::Schema<Page> = StoicSchema::Schema.object(Page.self, default: Page()) {
                        StoicSchema::Field("ids", \\.ids, .lossyArray(of: .int(.range(0 ... 9)), .count(...4)))
                        StoicSchema::Field("maybe", \\.maybe, .optional(.lossyArray(of: .array(of: .string()))))
                    }
                }

                extension Page: StoicSchema::Schematic {
                }
                """)
    }

    @Test func codableTypesAreReadByJSONDecoder() {
        expand(
            """
            @Schema
            struct Holder {
                @Codable var payload: Payload
                @Codable var many: [Payload]? = nil
                @Codable var byName: [String: Payload] = [:]
            }
            """,
            to: """
                struct Holder {
                    var payload: Payload
                    var many: [Payload]? = nil
                    var byName: [String: Payload] = [:]

                    static let schema: StoicSchema::Schema<Holder> = StoicSchema::Schema.object(Holder.self) { f in
                        let slot0 = f.field("payload", \\.payload, .codable(Payload.self))
                        let slot1 = f.field("many", \\.many, .optional(.array(of: .codable(Payload.self))), default: nil)
                        let slot2 = f.field("byName", \\.byName, .dictionary(of: .codable(Payload.self)), default: [:])
                        return f.build { v in
                            Holder(payload: v[slot0], many: v[slot1], byName: v[slot2])
                        }
                    }
                }

                extension Holder: StoicSchema::Schematic {
                }
                """)
    }
}
#endif
