#if STOIC_MACROS
import SwiftDiagnostics
import Testing

/// Every way `@Schema` and its attributes can be wrong, with the line it
/// points at. A diagnostic is the product: each of these is a mistake that
/// would otherwise be a trap, a failed suite or a puzzling compiler error
/// somewhere in generated code.
@Suite("@Schema: diagnostics about the declaration")
struct DeclarationDiagnosticTests {
    @Test func onlyStructsAndEnumsHaveSchemas() {
        expand(
            """
            @Schema
            class Reference {
                var x = 1
            }

            @Schema
            actor Isolated {
                var x = 1
            }

            @Schema
            struct Box<Wrapped> {
                var x = 1
            }

            @Schema
            enum Choice<Wrapped>: String {
                case a
            }

            @Schema
            enum Nothing: String {}
            """,
            diagnostics: [
                problem("@Schema applies to a struct or an enum", 1, 1),
                problem("@Schema applies to a struct or an enum", 6, 1),
                problem("@Schema cannot describe a generic type: a static property of a generic type belongs to each specialization, and a schema needs one", 12, 11),
                problem("@Schema cannot describe a generic type: a static property of a generic type belongs to each specialization, and a schema needs one", 17, 12),
                problem("`Nothing` has no cases, so its schema would accept nothing", 22, 6),
            ],
            to: """
                class Reference {
                    var x = 1
                }
                actor Isolated {
                    var x = 1
                }
                struct Box<Wrapped> {
                    var x = 1
                }
                enum Choice<Wrapped>: String {
                    case a
                }
                enum Nothing: String {}
                """)
    }

    @Test func aSchemaThatIsAlreadyThere() {
        expand(
            """
            @Schema
            struct Twice {
                var x = 1
                static let schema = 5
            }
            """,
            diagnostics: [
                problem("@Schema writes `static let schema`, and this type already has one: remove it, or remove @Schema and keep the schema written by hand", 4, 16),
            ],
            to: """
                struct Twice {
                    var x = 1
                    static let schema = 5
                }
                """)
    }

    @Test func theDefaultInstanceMustExist() {
        expand(
            """
            @Schema
            struct Custom {
                var x: Int
                init(x: Int) { self.x = x }
            }

            @Schema
            struct Fine {
                var x = 1
                init() {}
                init(x: Int) { self.x = x }
            }
            """,
            diagnostics: [
                problem("`x` has no default value, and the schema's default instance is `Custom()`; give it one", 3, 9, fixIts: ["give `x` the default `0`"]),
                problem("`Custom` declares initializers but no `init()`, and the schema builds its default instance with `Custom()`; add `init() {}` (every property needs a default)", 2, 8),
            ],
            to: """
                struct Custom {
                    var x: Int
                    init(x: Int) { self.x = x }
                }
                struct Fine {
                    var x = 1
                    init() {}
                    init(x: Int) { self.x = x }

                    static let schema: StoicSchema::Schema<Fine> = StoicSchema::Schema.object(Fine.self, default: Fine()) {
                        StoicSchema::Field("x", \\.x, .int())
                    }
                }

                extension Fine: StoicSchema::Schematic {
                }
                """)
    }
}

@Suite("@Schema: diagnostics about a property")
struct PropertyDiagnosticTests {
    @Test func everyPropertyNeedsADefault() {
        expand(
            """
            @Schema
            struct Missing {
                var count: Int
                var name: String
                var ratio: Double
                var flag: Bool
                var list: [Int]
                var map: [String: Int]
                var inner: Inner
                var maybe: Int?
            }
            """,
            diagnostics: [
                problem("`count` has no default value, and the schema's default instance is `Missing()`; give it one", 3, 9, fixIts: ["give `count` the default `0`"]),
                problem("`name` has no default value, and the schema's default instance is `Missing()`; give it one", 4, 9, fixIts: ["give `name` the default `\"\"`"]),
                problem("`ratio` has no default value, and the schema's default instance is `Missing()`; give it one", 5, 9, fixIts: ["give `ratio` the default `0`"]),
                problem("`flag` has no default value, and the schema's default instance is `Missing()`; give it one", 6, 9, fixIts: ["give `flag` the default `false`"]),
                problem("`list` has no default value, and the schema's default instance is `Missing()`; give it one", 7, 9, fixIts: ["give `list` the default `[]`"]),
                problem("`map` has no default value, and the schema's default instance is `Missing()`; give it one", 8, 9, fixIts: ["give `map` the default `[:]`"]),
                problem("`inner` has no default value, and the schema's default instance is `Missing()`; give it one", 9, 9),
            ],
            to: """
                struct Missing {
                    var count: Int
                    var name: String
                    var ratio: Double
                    var flag: Bool
                    var list: [Int]
                    var map: [String: Int]
                    var inner: Inner
                    var maybe: Int?
                }
                """)
    }

    @Test func aSchemaWritesToItsProperties() {
        expand(
            """
            @Schema
            struct Constants {
                let id = 1
                let name: String
            }
            """,
            diagnostics: [
                problem("`id` is a constant, and a schema writes to the properties it decodes into; declare it `var`, or mark it `@Ignored`", 3, 9, fixIts: ["declare `id` with `var`"]),
                problem("`name` is a constant, and a schema writes to the properties it decodes into; declare it `var`, or mark it `@Ignored`", 4, 9, fixIts: ["declare `name` with `var`"]),
            ],
            to: """
                struct Constants {
                    let id = 1
                    let name: String
                }
                """)
    }

    @Test func theMacroReadsTypesAsWritten() {
        expand(
            """
            @Schema
            struct Untyped {
                var a = Self.base
                var b = compute()
                var c = [1, 2]
                var d = nil as Int?
            }
            """,
            diagnostics: [
                problem("the macro cannot see the type of `a`: it reads types as they are written, so declare it (`var a: Type = …`)", 3, 9),
                problem("the macro cannot see the type of `b`: it reads types as they are written, so declare it (`var b: Type = …`)", 4, 9),
                problem("the macro cannot see the type of `c`: it reads types as they are written, so declare it (`var c: Type = …`)", 5, 9),
                problem("the macro cannot see the type of `d`: it reads types as they are written, so declare it (`var d: Type = …`)", 6, 9),
            ],
            to: """
                struct Untyped {
                    var a = Self.base
                    var b = compute()
                    var c = [1, 2]
                    var d = nil as Int?
                }
                """)
    }

    @Test func typesWithNoSchemaAreRefusedByName() {
        expand(
            """
            @Schema
            struct Unsupported {
                var a: Set<Int> = []
                var b: Character = "a"
                var c: Float = 0
                var d: (Int, Int) = (0, 0)
                var e: () -> Void = {}
                var f: Int! = 0
                var g: [Int: String] = [:]
                var h: any Sendable = 0
                var i: CGFloat = 0
                var j: Dictionary<Int, Int> = [:]
                var k: [Set<Int>] = []
            }
            """,
            diagnostics: [
                problem("`a`: `Set` has no schema: use an array with `@Unique`", 3, 12),
                problem("`b`: `Character` has no schema: use `String` with `@Length(1...1)`", 4, 12),
                problem("`c`: `Float` has no schema: use `Double`", 5, 12),
                problem("`d`: a tuple has no JSON shape; declare a struct", 6, 12),
                problem("`e`: a function cannot be read from JSON", 7, 12),
                problem("`f`: an implicitly unwrapped optional hides whether the key is required; write `Int?`", 8, 12),
                problem("`g`: a dictionary needs `String` keys to be a JSON object, not `Int`; use an array of entries instead", 9, 13),
                problem("`h`: an existential or opaque type has no single schema; use the concrete type", 10, 12),
                problem("`i`: `CGFloat` has no schema: use `Double`", 11, 12),
                problem("`j`: a dictionary needs `String` keys to be a JSON object, not `Int`", 12, 23),
                problem("`k`: `Set` has no schema: use an array with `@Unique`", 13, 13),
            ],
            to: """
                struct Unsupported {
                    var a: Set<Int> = []
                    var b: Character = "a"
                    var c: Float = 0
                    var d: (Int, Int) = (0, 0)
                    var e: () -> Void = {}
                    var f: Int! = 0
                    var g: [Int: String] = [:]
                    var h: any Sendable = 0
                    var i: CGFloat = 0
                    var j: Dictionary<Int, Int> = [:]
                    var k: [Set<Int>] = []
                }
                """)
    }

    @Test func aFormatNeedsTheTypeItIsAbout() {
        expand(
            """
            @Schema
            struct Wrong {
                @DateFormat(.epochSeconds) var a: String = ""
                @URLFormat(.relative) var b: Date = Date()
                @Range(1...5) var c: Date = Date()
                @DataFormat(.base64url) var d: Port = Port()
                @DateFormat(.iso8601) @DateFormat(.epochSeconds) var e: Date = Date()
                @Length(1...5) var f: UUID = UUID()
                @DateFormat(.epochSeconds) var ok: [String: Date?] = [:]
            }
            """,
            diagnostics: [
                problem("@DateFormat is about a `Date`, and `a` is `String`", 3, 5, fixIts: ["remove @DateFormat"]),
                problem("@URLFormat is about a `URL`, and `b` is `Date`", 4, 5, fixIts: ["remove @URLFormat"]),
                problem("@Range needs a number, and `c` is `Date`", 5, 5, fixIts: ["remove @Range"]),
                problem("@DataFormat cannot be applied to `d`: the macro cannot look inside `Port`, so it cannot tell that it is a Data. Put the format in that type's own schema", 6, 5, fixIts: ["remove @DataFormat"]),
                problem("@DateFormat appears twice on `e`", 7, 27, fixIts: ["remove the second @DateFormat"]),
                problem("@Length needs a string, and `f` is `UUID`", 8, 5, fixIts: ["remove @Length"]),
            ],
            to: """
                struct Wrong {
                    var a: String = ""
                    var b: Date = Date()
                    var c: Date = Date()
                    var d: Port = Port()
                    var e: Date = Date()
                    var f: UUID = UUID()
                    var ok: [String: Date?] = [:]
                }
                """)
    }

    @Test func onlyStoredInstancePropertiesAreFields() {
        expand(
            """
            @Schema
            struct Shapes {
                var (a, b) = (1, 2)
                @Key("c") static var shared = 1
                @Range(1...5) var computed: Int { 3 }
                @Ignored @Range(1...5) var ignored = 3
                var observed = 1 { didSet {} }
                static var counter = 0
                var computedToo: Int { 3 }
            }
            """,
            diagnostics: [
                problem("declare one property per name: the schema needs each property's name and type", 3, 9),
                problem("@Key on a static property: a schema describes the instance's stored properties", 4, 5),
                problem("@Range on a computed property: a schema describes stored properties, and `computed` stores nothing", 5, 5, fixIts: ["remove @Range"]),
                problem("@Range has no meaning on a property marked `@Ignored`, which the schema leaves out", 6, 14),
            ],
            to: """
                struct Shapes {
                    var (a, b) = (1, 2)
                    static var shared = 1
                    var computed: Int { 3 }
                    var ignored = 3
                    var observed = 1 { didSet {} }
                    static var counter = 0
                    var computedToo: Int { 3 }
                }
                """)
    }
}

@Suite("@Schema: diagnostics about the attributes")
struct AttributeDiagnosticTests {
    @Test func keysMustBeLiteralsAndDistinct() {
        expand(
            """
            @Schema
            struct Keys {
                @Key("") var a = 1
                @Key(name) var b = 1
                @Key("same") var c = 1
                @Key("same") var d = 1
                var e = 1
                @Key("e") var f = 1
                @Aliases("g") var g = 1
                @Aliases("h", other) var h = 1
                @Aliases("a2") var i = 1
                @Aliases("a2") var j = 1
                @Deprecated(message) var k = 1
            }
            """,
            diagnostics: [
                problem("a key cannot be empty", 3, 5),
                problem("the argument of @Key must be a string literal, so that the macro can read it", 4, 10),
                problem("an alias must be a string literal, so that it can be checked against the other keys", 10, 19),
                problem("the deprecation message must be a string literal", 13, 17),
                problem("the key \"same\" is `d`'s, and `c` already uses it; give one a different @Key or alias", 6, 5),
                problem("the key \"e\" is `f`'s, and `e` already uses it; give one a different @Key or alias", 8, 5),
                problem("the alias \"g\" is `g`'s own key already; an alias is another spelling", 9, 14),
                problem("the key \"a2\" is `j`'s, and `i` already uses it; give one a different @Key or alias", 12, 14),
            ],
            to: """
                struct Keys {
                    var a = 1
                    var b = 1
                    var c = 1
                    var d = 1
                    var e = 1
                    var f = 1
                    var g = 1
                    var h = 1
                    var i = 1
                    var j = 1
                    var k = 1
                }
                """)
    }

    @Test func anAttributeIsGivenOnce() {
        expand(
            """
            @Schema
            struct Twice {
                @Secret @Secret var a = ""
                @Key("x") @Key("y") var b = 1
                @Range(1...2) @Range(1...3) var c = 1
            }
            """,
            diagnostics: [
                problem("@Secret appears twice on `a`", 3, 13, fixIts: ["remove the second @Secret"]),
                problem("@Key appears twice on `b`", 4, 15, fixIts: ["remove the second @Key"]),
                problem("@Range appears twice on `c`", 5, 19, fixIts: ["remove the second @Range"]),
            ],
            to: """
                struct Twice {
                    var a = ""
                    var b = 1
                    var c = 1
                }
                """)
    }

    @Test func attributesNeedASchemaAroundThem() {
        expand(
            """
            struct Plain {
                @Range(1...5) var a = 1
                @Key("b") var b = 1
            }

            enum Choice: String {
                @Secret case a
            }
            """,
            diagnostics: [
                problem("@Range means something only inside a type marked @Schema", 2, 5),
                problem("@Key means something only inside a type marked @Schema", 3, 5),
                problem("@Secret means something only inside a type marked @Schema", 7, 5),
            ],
            to: """
                struct Plain {
                    var a = 1
                    var b = 1
                }

                enum Choice: String {
                    case a
                }
                """)
    }
}

@Suite("@Schema: diagnostics about its arguments")
struct ArgumentDiagnosticTests {
    @Test func argumentsBelongToTheKindOfType() {
        expand(
            """
            @Schema(discriminator: "kind")
            struct S {
                var x = 1
            }

            @Schema(unknownKeys: .reject)
            enum U {
                case a(Int)
            }

            @Schema(version: 2)
            enum V: String {
                case a
            }

            @Schema(name: "R")
            enum W: String {
                case a
            }
            """,
            diagnostics: [
                problem("`discriminator:` applies to an enum with associated values, and this is a struct", 1, 9, fixIts: ["remove `discriminator:`"]),
                problem("`unknownKeys:` applies to a struct, and this is an enum with associated values", 6, 9, fixIts: ["remove `unknownKeys:`"]),
                problem("`version:` applies to a struct, and this is an enumeration of raw values", 11, 9, fixIts: ["remove `version:`"]),
                problem("`name:` applies to a struct or an enum with associated values, and this is an enumeration of raw values", 16, 9, fixIts: ["remove `name:`"]),
            ],
            to: """
                struct S {
                    var x = 1
                }
                enum U {
                    case a(Int)
                }
                enum V: String {
                    case a
                }
                enum W: String {
                    case a
                }
                """)
    }

    @Test func versionsNeedEachOther() {
        expand(
            """
            @Schema(migrations: [])
            struct A {
                var x = 1
            }

            @Schema(versionKey: "v")
            struct B {
                var x = 1
            }

            @Schema(missingVersion: .current)
            struct C {
                var x = 1
            }

            @Schema(version: 0)
            struct D {
                var x = 1
            }

            @Schema(version: 2)
            struct E {
                var version = 1
            }

            @Schema(version: 2, versionKey: "v")
            struct F {
                @Key("v") var x = 1
            }
            """,
            diagnostics: [
                problem("`migrations:` lead to the current `version:`, and none is given", 1, 9),
                problem("`versionKey:` names where `version:` is written, and none is given", 6, 9),
                problem("`missingVersion:` says what a document without a version means, and there is no `version:`", 11, 9),
                problem("a version is a positive integer, not 0", 16, 9),
                problem("\"version\" holds the document's version, and `version` is written under it; give the field another @Key or set `versionKey:`", 21, 9),
                problem("\"v\" holds the document's version, and `x` is written under it; give the field another @Key or set `versionKey:`", 26, 9),
            ],
            to: """
                struct A {
                    var x = 1
                }
                struct B {
                    var x = 1
                }
                struct C {
                    var x = 1
                }
                struct D {
                    var x = 1
                }
                struct E {
                    var version = 1
                }
                struct F {
                    var x = 1
                }
                """)
    }

    @Test func unknownKeysArePreservedOrGivenAPolicy() {
        expand(
            """
            @Schema(unknownKeys: .reject)
            struct A {
                @PreserveUnknownKeys var extra = JSONObject()
            }

            @Schema(unknownKeys: .preserve)
            struct B {
                var x = 1
            }

            @Schema
            struct C {
                @PreserveUnknownKeys var extra = 1
            }

            @Schema
            struct D {
                @PreserveUnknownKeys var one = JSONObject()
                @PreserveUnknownKeys var two = JSONObject()
            }
            """,
            diagnostics: [
                problem("`unknownKeys:` and @PreserveUnknownKeys both say what happens to unknown keys; the property that keeps them makes the policy `.preserve`, so drop `unknownKeys:`", 1, 9),
                problem("`.preserve` keeps unknown keys in a property: mark a `JSONObject` property with @PreserveUnknownKeys", 6, 9),
                problem("@PreserveUnknownKeys needs a property of type `JSONObject`, and `extra` is `Int`", 13, 5),
                problem("only one property can keep the unknown keys, and `one` already does", 19, 5),
            ],
            to: """
                struct A {
                    var extra = JSONObject()
                }
                struct B {
                    var x = 1
                }
                struct C {
                    var extra = 1
                }
                struct D {
                    var one = JSONObject()
                    var two = JSONObject()
                }
                """)
    }
}

@Suite("@Schema: diagnostics about an enum")
struct EnumDiagnosticTests {
    @Test func anEnumNeedsSomethingToWrite() {
        expand(
            """
            @Schema
            enum Plain {
                case a, b
            }

            @Schema
            enum Inherits: Sendable {
                case a, b
            }

            @Schema
            enum Wide: Double {
                case a = 1.5
            }
            """,
            diagnostics: [
                problem("`Plain` has no raw type and no associated values, so the schema has nothing to write: give it a `String` or `Int` raw type, or associated values", 2, 6, fixIts: ["give `Plain` the raw type `String`"]),
                problem("`Inherits` has no raw type and no associated values, so the schema has nothing to write: give it a `String` or `Int` raw type, or associated values", 7, 6, fixIts: ["give `Inherits` the raw type `String`"]),
                problem("an enumeration is written as its raw value, and the schema reads only `String` and `Int` raw values, not `Double`", 12, 12),
            ],
            to: """
                enum Plain {
                    case a, b
                }
                enum Inherits: Sendable {
                    case a, b
                }
                enum Wide: Double {
                    case a = 1.5
                }
                """)
    }

    @Test func rawValuesAreWhatIsWritten() {
        expand(
            """
            @Schema
            enum Raw: String {
                @Key("x") case a
                @Range(1...2) case b
            }
            """,
            diagnostics: [
                problem("@Key does not apply to the case of an enumeration with a raw type: its raw value is what is written, so give the case one (`case a = \"…\"`)", 3, 5),
                problem("@Range does not apply to the case of an enumeration with a raw type: its raw value is what is written, so give the case one (`case b = \"…\"`)", 4, 5),
            ],
            to: """
                enum Raw: String {
                    case a
                    case b
                }
                """)
    }

    @Test func tagsAreUniqueAndLabelled() {
        expand(
            """
            @Schema
            enum Tags {
                case a(Int)
                @Key("a") case b(String)
                @Key("") case c
                @Key(tag) case d
                @Key("e") @Key("f") case e
                @Range(1...2) case f
            }

            @Schema(discriminator: "value")
            enum Keys {
                case a(Int)
            }

            @Schema
            enum Unlabelled {
                case pair(Int, Int)
                case mixed(Int, second: Int)
                case set(Set<Int>)
            }
            """,
            diagnostics: [
                problem("a tag cannot be empty", 5, 5),
                problem("the argument of @Key must be a string literal, so that the macro can read it", 6, 5),
                problem("@Key appears twice on `e`", 7, 15, fixIts: ["remove the second @Key"]),
                problem("@Range does not apply to a case of a union; a payload's own schema holds its constraints", 8, 5),
                problem("`b` is written as \"a\", the tag of `a` already; give one a different @Key", 4, 20),
                problem("the discriminator and the value key are both \"value\"; they must differ", 11, 9),
                problem("`pair` carries several values, which are written as an object: name each one (`case pair(first: …, second: …)`) so that it has a key", 18, 14),
                problem("`mixed` carries several values, which are written as an object: name each one (`case mixed(first: …, second: …)`) so that it has a key", 19, 15),
                problem("`set`: `Set` has no schema: use an array with `@Unique`", 20, 14),
            ],
            to: """
                enum Tags {
                    case a(Int)
                    case b(String)
                    case c
                    case d
                    case e
                    case f
                }
                enum Keys {
                    case a(Int)
                }
                enum Unlabelled {
                    case pair(Int, Int)
                    case mixed(Int, second: Int)
                    case set(Set<Int>)
                }
                """)
    }
}
#endif
