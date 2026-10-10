# 13 · Build enforcement

A convention nobody checks is a suggestion. Stoic's rules (bound every wait,
no escape hatch without a reason, no blocking in async code) live in
AGENTS.md and in review comments, and they erode at the speed of a deadline.
This contract moves them into the build: the patterns Stoic exists to replace
fail the build, with a message that names the replacement.

It works in three layers, because no single mechanism can do the whole job.
The order is the order of DESIGN.md principle 8: the compiler first, the
build plugin second, the docs third.

## The three layers

**(a) Stoic builds itself with warnings as errors.** Every Stoic target
carries `.treatAllWarnings(as: .error)`, strict memory safety and the
upcoming-feature flags (`Package.swift`, `strict`). A library that asks apps
to be strict cannot ship code that is not. This binds Stoic's own sources
only: SwiftPM strips warning-control settings from a package built as a
dependency (SE-0480), so a library _cannot_ force them on the app that uses
it. That is the right default for a dependency, and the reason layers (b) and
(c) exist.

**(b) The app turns the compiler up on its own targets.** Swift 6 language
mode makes data races errors; warnings-as-errors makes everything else the
compiler knows into one. This is the cheapest layer and catches the most. It
is the app's manifest that must say so:

```swift
.target(
    name: "App",
    dependencies: [.product(name: "Stoic", package: "stoic")],
    swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
        .strictMemorySafety(),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]
)
```

In an Xcode project the same settings are `SWIFT_VERSION = 6` and
`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`. (For one noisy warning group,
SE-0443's `-Wwarning <group>` keeps it a warning while everything else
errors.)

**(c) The lint plugin catches what the compiler cannot see.** The compiler
accepts `semaphore.wait()` in a wrapper type, `Task.detached`, an
`AsyncStream` with its default unbounded buffer, `try?` on a statement,
`@unchecked Sendable` with no stated reason. They are legal, and the
robustness bugs Stoic exists to prevent. `StoicLint` is a build-tool plugin
that parses the target's sources and fails the build on them.

Where the layers overlap, the compiler's diagnostic wins and the lint stays
quiet only by being syntactic: on a `DispatchSemaphore` the compiler already
rejects `wait()` in async code ("unavailable from asynchronous contexts"),
and the lint rule fires too, because it also covers wrappers the compiler
cannot judge. Two errors for one line is acceptable; a silent miss is not.

## Origin

- **SwiftLint's plugin model.** A build-tool plugin runs a host tool over a
  target's sources and turns its output into build issues, with a baseline for
  adoption. Stoic's differs in scope (rules about robustness, not style, all
  errors, none warnings) and in carrying its own parser, so it needs no
  installed binary.
- **SE-0443, SE-0480 and the warning-control family.** Warning groups and
  `-Werror <group>` (SE-0443), and SwiftPM settings built on them (SE-0480),
  are layer (b). SE-0522 is named in the brief for this work and its text was
  not re-read for this document; nothing here depends on it.
- **Rust's clippy.** Lints that name the replacement ("use `x.is_empty()`")
  and a `#[allow(clippy::x)]` that sits beside the code, rather than a global
  switch. `// stoic:allow(rule): reason` is that, with the reason mandatory.
- **Ratchets.** Record today's violations, fail on any new one, let the count
  fall and never rise (the technique from large-codebase lint migrations, and
  from `cargo clippy` baselines in CI). A rule that cannot be adopted gradually
  is not adopted.

## API

### Enabling it

Consumers opt in with the `Lint` trait, which is what makes swift-syntax a
dependency at all (see [Packaging](#packaging-and-the-lint-trait)):

```swift
// Package.swift of the app
let package = Package(
    name: "App",
    dependencies: [
        .package(url: "https://github.com/Vaccone-Software/stoic", from: "0.1.0", traits: ["Lint"]),
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [.product(name: "Stoic", package: "stoic")],
            swiftSettings: [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)],
            plugins: [.plugin(name: "StoicLint", package: "stoic")]
        ),
    ]
)
```

In an Xcode project, add the Stoic package with the `Lint` trait, then add
`StoicLint` to the target's "Run Build Tool Plug-ins" phase. (The Xcode entry
point shares the SwiftPM command and is compiled only under
`canImport(XcodeProjectPlugin)`; it has not been exercised against a real
project yet.)

### The tool

```
stoic-lint [--baseline <file>] [--output <stamp>] <path>…
stoic-lint --write-baseline <file> <path>…
swift run --traits Lint stoic-lint Sources        # in a checkout of Stoic
```

Each `<path>` is a Swift file or a directory searched for `*.swift` (hidden
directories are skipped). Exit status: `0` clean, `1` findings that fail the
build, `2` the tool could not run (bad arguments, unreadable file, the
trait-off stub).

### Diagnostics

The format Xcode and SwiftPM both parse out of tool output:

```
/abs/path/File.swift:12:5: error: [stoic.blocking-in-async] `wait()` parks a thread of the cooperative pool inside async code; …
/abs/path/File.swift:12:5: note: use `AsyncSemaphore` / `AsyncMutex`, or `await` the work directly
stoic-lint: 1 error(s) in 1 file(s)
```

Line is one-based, column is one-based in UTF-8 bytes (what Xcode counts).
The `note:` carries the replacement in words. A baselined finding is the same
line with `warning:` and no note.

### Suppression

```swift
// stoic:allow(unchecked-sendable): every access to `value` goes through `lock`
final class Box: @unchecked Sendable { … }

let handle = try! open() // stoic:allow(force-try): created by the build step above
```

The comment goes on the offending line, or alone on the line above it. For a
declaration or statement that spans lines, the comment above its first line
covers the whole of it. `stoic:allow(a, b): reason` names several rules; both
`force-try` and `stoic.force-try` are accepted.

### Baseline

A baseline file lists accepted findings. If `.stoic-lint-baseline.json`
exists at the package root (or the Xcode project's folder), the plugin passes
it as `--baseline` and declares it an input.

```
stoic-lint --write-baseline .stoic-lint-baseline.json Sources
```

```json
{
  "entries": [
    {
      "file": "Sources/App/Legacy.swift",
      "hash": "9ca4c22665d8892f",
      "rule": "stoic.discarded-try"
    }
  ],
  "version": 1
}
```

## Semantics

**Syntactic, on purpose.** The linter parses; it does not type-check. It sees
`semaphore.wait()` and `Task.detached`, not that `semaphore` is a
`DispatchSemaphore`. So rules match the shape a pattern takes in practice and
prefer a missed finding to a false one: a finding is a build error, and an
error the author cannot trust trains people to suppress without reading. A
false positive is a bug in the rule; a false negative is a known limit,
written in the rule's row below.

**Every rule is an error.** There is no warning severity for a rule. The one
`warning:` is a finding the baseline accepted, which is "an error we agreed
to postpone", and it is reported so the debt stays visible.

**Suppression needs a reason.** A `stoic:allow` comment without a reason
(`// stoic:allow(force-try)`, or an empty one after the colon) suppresses
nothing and is itself a finding, `stoic.allow-without-reason`, which is not
suppressible. So the original finding and the missing reason both show until
a reason is written. A comment on the line above covers the next line only if
it stands alone on its line; a trailing comment after code speaks for its own
line, so it cannot silently excuse whatever happens to follow. Only a comment
that _starts_ with the marker counts, so documentation that mentions the
syntax is left alone, and a string literal containing it is not a comment.

**What "inside async code" means.** For `blocking-in-async` a body is async
when it is an `async` function, initializer or accessor; a method or computed
property of an `actor` (a blocked synchronous actor method blocks the actor's
executor; `nonisolated` and `static` members are exempt); a closure marked
`async`; or a closure passed to something that runs it as a task (`Task`,
`Task.detached`, `group.addTask`, `withTaskGroup` and its siblings,
`MainActor.run`, and Stoic's `withTimeout`, `withDeadline`, `retry`, `recur`,
`withScope`, `withTaskScope`, `race`, `hedge`, `mapConcurrent`,
`withContext`, `withPermit`). Any other closure is synchronous, even inside
an async function. That misses `items.map { sleep(1) }` in an async function,
and it is deliberate: `DispatchQueue.global().async { semaphore.wait() }`
blocks a Dispatch thread, not the cooperative pool, and is the sanctioned way
to bridge blocking code. The rule must not call the bridge a bug.

**What "discarded" means.** `discarded-try` flags `try?` as a statement
(`try? save()`, `try? await sync()`) and `_ = try? f()`. It does not flag a
used result (`let x = try? f()`, `return try? f()`, `if let x = try? f()`,
`try? f() ?? d`). A lone `try? f()` that is a body's value is also not
flagged: a closure, a function with a non-`Void` return, a getter, or an
`if`/`switch` expression in value position. The exception to the exception is
a `Task { try? await f() }` that is itself a statement, because nobody can
read that task's result.

**Test code.** `force-try` skips a file whose path contains `/Tests/` or whose
name ends in `Tests.swift`: a crash in a test is a failing test. No other
rule has a test exemption. (A project that lives under a directory named
`Tests` is not linted by `force-try` at all; keep sources out of it.)

**Build integration.** The plugin creates one `.buildCommand` per target over
its Swift sources. The inputs are the sources (and the baseline); the one
declared output is a stamp file `<Target>.stoic-lint-stamp` in the plugin work
directory, which the tool writes **only when the run passes**. The build
system reruns the command when an input changes, and a failing run leaves no
stamp, so it reruns on every build until the findings are fixed; a failure
cannot go quiet by being cached. The command ordering relative to compilation
is the build system's: in the end-to-end run below both the compiler's and the
linter's errors appear in one build.

**Baseline identity.** An entry is `(file path relative to the baseline's
directory, rule, FNV-1a hash of the trimmed offending line)`. No line numbers:
adding a function above a baselined line moves it without changing its
identity, so the baseline does not churn on unrelated commits. Changing the
offending line itself makes it a new finding, which is the right moment to
look at it again. Identical lines are separate entries and each accepts one
finding: a copy-pasted third occurrence is new.

**The count may only fall.** Findings in the baseline are warnings; findings
not in it are errors. Fix one and its entry no longer matches: the build
passes and warns that the baseline has stale entries
(`[stoic.baseline]`, attached to the baseline file). Regenerate with
`--write-baseline` and the ratchet turns down. Nothing turns it up except
doing that regeneration on purpose, in a diff a reviewer sees. Entries for
files outside a run (another target's) are not reported as stale. The hash is
FNV-1a, not Swift's `Hasher`, which is seeded per process and would make a
baseline unreadable tomorrow.

## Rules

All rules are errors. Fixes are advice in words, never an automatic rewrite:
the right replacement depends on code the linter does not read.

| Id                           | Flags                                                                                                                                                                                         | Why                                                                                                                                                   | Instead                                                                                                    |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `stoic.blocking-in-async`    | In async code (above): `x.wait()` / `wait(timeout:)` on a semaphore- or group-looking receiver, `sleep(n)`, `usleep(n)` (also `Darwin.`/`Glibc.`-qualified), `Thread.sleep`, `queue.sync { }` | Parks a cooperative-pool thread; the pool is about one thread per core, so it starves or deadlocks under load. Not cancellable, not on the test clock | `AsyncSemaphore` / `AsyncMutex`; `try await Ambient.sleep(for:)`; make the work `async` and `await` it     |
| `stoic.unchecked-sendable`   | `@unchecked Sendable` in any conformance, including extensions                                                                                                                                | Switches the data-race check off by assertion                                                                                                         | A real `Sendable` type, an actor, `Mutex`-guarded state; or justify with `stoic:allow`                     |
| `stoic.nonisolated-unsafe`   | `nonisolated(unsafe)` on any declaration                                                                                                                                                      | Exempts the declaration from data-race checking                                                                                                       | `Mutex` or an actor; or justify with `stoic:allow`                                                         |
| `stoic.unbounded-stream`     | `AsyncStream` / `AsyncThrowingStream` created with `init` or `makeStream` without `bufferingPolicy:`, or with `.unbounded`. `unfolding:` streams are exempt (pull-based)                      | The default buffer is unbounded: a fast producer grows memory until the app is killed (principle 2)                                                   | `Channel(capacity:overflow:)`, or `bufferingPolicy: .bufferingNewest(n)`                                   |
| `stoic.discarded-try`        | `try?` whose result is discarded: a statement, or `_ = try? …`                                                                                                                                | The error, its cause and what the code was doing vanish; nothing records that it failed                                                               | Handle the error, or let it propagate through `withContext("what I was doing") { … }`                      |
| `stoic.force-try`            | `try!` outside test code. Exempt: `Regex("literal")` and `NSRegularExpression(pattern: "literal")` (a constant pattern fails every time or never)                                             | A crash with no message and no context is the failure handler                                                                                         | Propagate with `try`, or handle; if it cannot fail, `stoic:allow(force-try): why`                          |
| `stoic.task-detached`        | `Task.detached` (also `Task<A, B>.detached`)                                                                                                                                                  | Loses task-locals: the ambient context, deadlines, cancellation causes. It runs on the wall clock with no bound                                       | `Task {}`, or a structured child (`withTaskGroup`, `withTaskScope`)                                        |
| `stoic.sleep-for-timeout`    | Any `.asyncAfter(` call                                                                                                                                                                       | A timer no scope owns, no deadline bounds, and a test clock cannot advance                                                                            | `withTimeout` to bound work; `Ambient.sleep(for:)` inside a task the caller owns. Justification is allowed |
| `stoic.allow-without-reason` | A `stoic:allow(…)` comment with no reason (or malformed). Not suppressible                                                                                                                    | "Allow" typed as a reflex defeats the rule                                                                                                            | `// stoic:allow(rule): why this is safe here`                                                              |

Known limits, all false negatives by design:

- `blocking-in-async` does not see a plain closure inside an async function
  (the bridge case), a closure whose async-ness comes from its inferred type
  (`let work: () async -> Void = { sleep(1) }`), or a receiver whose name does
  not read like a semaphore or group (`let latch = DispatchSemaphore(…)`
  then `latch.wait()` is missed; `sem`, `semaphore`, `…Group` and
  `DispatchSemaphore(…)` are caught). `queue.sync` needs "queue" in the
  receiver's spelling.
- `unbounded-stream` trusts a `bufferingPolicy:` passed as a variable.
- `discarded-try` does not follow `try?` through a closure's inferred
  `Void` return.

## Failure modes

| What happens if…                                               | Behaviour                                                                                                        |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| a source file has syntax errors                                | SwiftParser recovers; the rules run on what parsed. The compiler reports the syntax error, not the linter        |
| the plugin is attached but the `Lint` trait is off             | The tool is a stub: prints "built without the Lint trait", exits 2, the build fails with that message            |
| the baseline file is missing or invalid                        | Exit 2 with the reason; the build fails. A baseline that cannot be read must not silently become "no baseline"   |
| the baseline has a newer `version`                             | Exit 2: "baseline version N is not supported"                                                                    |
| a baselined finding is fixed                                   | Build passes; warning `[stoic.baseline]` that entries are stale                                                  |
| a new finding appears with a baseline present                  | Error; baselined ones stay warnings                                                                              |
| a baselined line is edited                                     | New finding (its hash changed); the old entry goes stale                                                         |
| a suppression has no reason                                    | Suppresses nothing; `stoic.allow-without-reason` plus the original finding                                       |
| a suppression names an unknown rule                            | Suppresses nothing; the original finding remains                                                                 |
| the tool fails after writing nothing                           | No stamp, so the next build runs it again                                                                        |
| a target has no Swift sources                                  | No command is created                                                                                            |
| a file is not valid UTF-8                                      | Decoded leniently (replacement characters); lines and columns of valid text are unaffected                       |
| the same file is passed twice, or a directory and a file in it | Linted once                                                                                                      |
| a path does not exist                                          | Exit 2                                                                                                           |
| a finding sits in generated code                               | Not special-cased; plugins receive the target's source files, and generated sources are the generator's business |

## Packaging and the `Lint` trait

SwiftPM ignores the warning-control settings of dependencies, so the plugin is
how Stoic reaches an app's build. The plugin needs a Swift parser, which means
swift-syntax, which is large and slow to build. A library that most users
never lint must not make every user fetch it.

What was found, by building Stoic and two scratch consumers:

- **A dependency used only by targets conditioned on a disabled trait is not
  fetched.** `swift build` in Stoic with no trait leaves `.build/checkouts`
  empty and writes no `Package.resolved`; a consumer that depends on Stoic
  without `traits: ["Lint"]` likewise. With `--traits Lint`, SwiftPM resolves
  swift-syntax 604.0.0 and builds it.
- **Targets cannot be conditioned on a trait; dependencies and build settings
  can.** SwiftPM builds every target of a package it builds, trait or no
  trait. So `StoicLintCore`, `stoic-lint` and the test target are always in
  the build graph. `Package.swift` conditions their swift-syntax products on
  `.when(traits: ["Lint"])` and gives each a `STOIC_LINT` define under the same
  condition (`.define("STOIC_LINT", .when(traits: …))`, a `BuildSettingCondition`
  that accepts traits). Every source file is wrapped in `#if STOIC_LINT`, so
  with the trait off the library compiles to an empty module and the test
  target to zero tests.
- **The executable is a stub when the trait is off.** `stoic-lint` must still
  link, so its `#else` branch is a `main` that prints that it was built without
  the trait and exits 2. Attaching the plugin without the trait therefore fails
  the build with an explanation, not with a missing file.
- **Plugin targets and plugin products are unconditional.** The `StoicLint`
  plugin is in the manifest regardless of the trait; it only works when the
  tool behind it is real.
- **The default `swift build` and `swift test` of the Stoic repo do not need
  swift-syntax**, and pass: 173 and 158 tests, and `StoicLintCoreTests`
  reports 0 tests. `swift test --traits Lint` runs 89 more.
- **Traits are additive across the graph.** If any package in an app's graph
  enables `Lint` on Stoic, it is on for all of it.
- **Switching traits in one checkout rebuilds**, and both configurations share
  `.build`: the `stoic-lint` binary there is whichever was built last. Run it
  with `swift run --traits Lint stoic-lint …` (the option goes _before_ the
  product name; after it, it is passed to the tool and the stub runs).
- **A path dependency's identity is its directory name**, so a consumer of a
  worktree writes `package: "stoic-lint"`, not `"stoic"`. From a URL it is
  `stoic`.

Stoic does not attach the plugin to its own targets: that would put
swift-syntax in every build of the repo. Its own sources are checked by running
the tool (below), and CI runs it as a step.

## Testing

Pure rules are tested from inline snippets, with Swift Testing, trait-gated
like the target: `swift test --traits Lint --filter StoicLintCoreTests`.

- **Per rule, positive and negative cases.** Including: a synchronous function
  calling `semaphore.wait()` is not flagged; an async closure inside a
  synchronous function is; actor methods are, `nonisolated` ones are not;
  `let x = try? f()` is not flagged; `try!` in a `/Tests/` path is not;
  `AsyncStream(bufferingPolicy: .bufferingNewest(1))` is not.
- **Suppression.** A reason suppresses; none does not and is reported; the
  qualified rule name works; a trailing comment does not speak for the next
  line; a justification above a multi-line declaration covers the clause;
  documentation and string literals that mention the marker are inert.
- **Golden test of the diagnostic format**, since Xcode and SwiftPM parse it,
  including the UTF-8 byte column.
- **Baseline.** JSON round trip and stable bytes; accepted findings are
  warnings and exit 0; a new finding fails; entries survive edits elsewhere
  in the file and indentation changes; editing the offending line is new;
  fixing leaves a stale entry and a warning; a duplicate is new; entries for
  files outside the run are not stale; pinned FNV-1a values so a baseline
  written today stays readable.
- **Command line.** Argument parsing, including bad usage.
- **End to end.** A scratch consumer package depends on the repository by path
  with `traits: ["Lint"]` and applies the plugin to a target full of
  violations. `swift build` fails with each `error: [stoic.…]` line; after
  fixing or justifying each, it passes. With a baseline: passes with warnings;
  a new finding fails; a fix leaves the stale warning. With the trait off, the
  stub's message. (Reproduce with the manifest in the Usage section.)
- **Self-check.** `swift run --traits Lint stoic-lint Sources Plugins
Package.swift` is clean.

## Non-goals

- **Style.** Formatting and naming are SwiftLint's and swift-format's.
- **Type-aware rules.** Anything that needs the type checker (is this
  receiver really a `DispatchSemaphore`?) belongs to the compiler's own
  diagnostics, or to a future rule built on index data. The linter stays a
  parser.
- **Automatic fixes.** Messages name the replacement; they do not rewrite.
  The right `Channel` capacity is a decision.
- **Warnings.** A rule that is not worth an error is not a rule.
- **A way to turn a rule off globally.** Suppression is per site, with a
  reason. To adopt a rule gradually, use the baseline.
- **Linting dependencies.** The plugin sees the sources of the target it is
  attached to.

## Planned

- A rule per primitive as it lands: a bare `Task.sleep` in code under test
  (use `Ambient.sleep`), a `while true` loop that catches and sleeps
  (`Supervisor`), a `catch { print(error) }` (`Report`), a retry loop written
  by hand.
- `@preconcurrency` without a reason, named in AGENTS.md rule 7 and not yet
  checked.
- A `--format` option for CI systems that want JSON or SARIF.
- `stoic-doctor`, which audits an app's manifest for layer (b) settings.
- Exercising the Xcode entry point against a real project.
