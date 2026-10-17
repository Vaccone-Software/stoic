#!/bin/sh
# The one command that says whether Stoic is healthy.
#
#   scripts/check.sh            build, test, sanitizers, lint, API, allocations, macros,
#                               package graph, adoption, iOS, docs
#   scripts/check.sh --stress   … and every suite 100 times
#
# Linux is scripts/linux.sh (a separate CI job). Every item of DESIGN.md's
# quality bar that a machine can check is checked here.
#
# Warnings are errors in every Stoic target, so a clean build is also a
# warning-free build.
set -eu
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$1"; }

# Swift Testing starts every test of a bundle at once. On a runner with a few
# cores that is hundreds of tests, and the processes some of them spawn,
# competing for the same cores, and a test that waits in real time for work of
# its own (a restart, a waiter, a cancelled child) can be starved for longer
# than its window. One test per core keeps a test's wait about its own work.
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-$(sysctl -n hw.ncpu)}
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH

step "package graph: every dependency allowed by the layering, declared and used"
graph=$(mktemp)
swift package dump-package > "$graph"
swift scripts/package-graph.swift "$graph"
rm -f "$graph"

step "build"
swift build

step "tests"
swift test

step "tests under Thread Sanitizer: the concurrency primitives (data races the model tests cannot see)"
# The suites that exercise shared mutable state across tasks: semaphore,
# channel, single-flight, TaskSlot, scopes, race/map, supervision, service
# graph, state machine, simulation, abandoning timeouts, the resilience
# policies, the idempotency key hedged attempts read at once, and declared
# operations (their admission partitions, breakers, settled marks and shielded
# attempts). A few minutes: the instrumented build is separate from the one above.
swift test --sanitize=thread --filter 'Semaphore|Channel|SingleFlight|TaskSlot|Scope|RaceAndMap|Supervis|ServiceGraph|StateMachine|Simulation|Abandoning|Hedge|CircuitBreaker|RateLimiter|Bulkhead|AttemptKey|Perform|Operation|Urgency'

step "tests under Address Sanitizer: every suite (memory errors the type system cannot rule out)"
# Skipped here, run with their bounds in the plain test step above: the tests
# that assert a wall-clock bound, which holds in a normal build and not under
# the sanitizer's several-fold slowdown; and the exit test that expects its
# child to succeed, which aborts under the sanitizer whatever its body does
# (a toolchain limitation).
swift test --sanitize=address \
    --skip 'openingTwentyThousandPendingEntriesIsFast|theTimeToOpenGrowsLinearlyNotQuadratically|didYouMeanIsComputedOnlyForIssuesThatAreRecorded|positionsOfAThousandIssuesOnOneLongLineCostOnePass|deepNestingIsRefusedNotACrash'

step "compile-fail: a Scope, TaskScope or Saga handle cannot escape its body (design/04)"
# Swift Testing cannot assert that code fails to compile, so each file in
# scripts/compile-fail is compiled through SIL (where the noncopyable and
# escaping-capture checks run) against the module just built. A file whose
# first line is `// expect-error: <text>` must fail with an error containing
# <text>; a file without one must compile (it proves the harness itself works,
# so an expect-error file cannot pass because the module was not found). About
# a quarter of a second per file.
bin=$(swift build --show-bin-path)
for file in scripts/compile-fail/*.swift; do
    expected=$(sed -n 's|^// expect-error: ||p' "$file" | head -1)
    status=0
    output=$(swiftc -emit-sil -o /dev/null -I "$bin" -I "$bin/Modules" -swift-version 6 \
        -enable-upcoming-feature ExistentialAny -enable-upcoming-feature NonisolatedNonsendingByDefault \
        "$file" 2>&1) || status=$?
    if [ -z "$expected" ]; then
        if [ "$status" -ne 0 ]; then
            printf '%s\n' "$output"
            printf 'FAIL %s: the control must compile\n' "$file"
            exit 1
        fi
    elif [ "$status" -eq 0 ]; then
        printf 'FAIL %s: it compiled, but must not (expected: %s)\n' "$file" "$expected"
        exit 1
    elif ! printf '%s\n' "$output" | grep 'error:' | grep -qF -- "$expected"; then
        printf '%s\n' "$output"
        printf 'FAIL %s: failed, but not with "%s"\n' "$file" "$expected"
        exit 1
    fi
    printf '  ok %s\n' "$file"
done

step "lint rule tests (Lint trait)"
swift test --traits Lint --filter StoicLintCoreTests

step "self-lint, against Stoic's escape budget (design/13)"
# A new `stoic:allow` fails here until .stoic-lint-baseline.json records it.
swift run --traits Lint stoic-lint --baseline .stoic-lint-baseline.json Sources Plugins Package.swift

step "examples lint: what agents copy is clean, with no baseline"
# Examples are exemplary or they are wrong: a finding here fails the build,
# and nothing is accepted.
swift run --traits Lint stoic-lint Examples

step "public API: no breaking change since the last release, unless allowed in writing"
# Compares every library product with the newest tag. An intentional break
# is listed, one API per line, in api-breakage-allowlist.txt, in the change
# that makes it, and the list is emptied at the next release.
if latest=$(git describe --tags --abbrev=0 2>/dev/null); then
    allowlist=""
    if [ -s api-breakage-allowlist.txt ]; then allowlist="--breakage-allowlist-path api-breakage-allowlist.txt"; fi
    # shellcheck disable=SC2086
    swift package diagnose-api-breaking-changes "$latest" $allowlist
else
    echo "no release tag to compare with (CI checks out with tags; a shallow local clone may not)"
    exit 1
fi

step "allocations: no hot path's median call allocates more than recorded (Benchmarks/allocations.json)"
# Time is reported, not gated (shared CI machines drift). The gate is the
# median allocations of one call, with no tolerance, except the few paths
# that start tasks, whose median the scheduler moves: each has a stated
# allowance (schedulerAllowance in Benchmarks). Fewer than recorded is
# reported so the record can be ratcheted down with --record.
(cd Benchmarks && swift run -c release StoicBenchmarks --check allocations.json)

step "macros (Macros trait): expansion tests, usage tests, schemas against their hand-written twins"
swift build --traits Macros
swift test --traits Macros --filter StoicMacros

step "sealed storage (Crypto trait): StoicSealed and StoicSealedKeychain build and their tests pass, with swift-crypto"
# swift-crypto is fetched only with the trait (the adoption step below proves
# an app without it fetches nothing), so the library and its tests are built
# and run here with it: all of them, then the concurrency tests under Thread
# Sanitizer and every one under Address Sanitizer.
swift build --traits Crypto
swift test --traits Crypto --filter 'StoicSealedTests|StoicSealedKeychainTests'
swift test --traits Crypto --sanitize=thread --filter 'StoicSealedTests|StoicSealedKeychainTests'
swift test --traits Crypto --sanitize=address --filter 'StoicSealedTests|StoicSealedKeychainTests'

step "adoption: an app adopting every library, with no traits, fetches nothing and builds; with Crypto, only swift-crypto"
# Also what proves a consumer that never enables Macros, Lint or Crypto never
# fetches swift-syntax or swift-crypto.
scripts/adoption.sh

step "iOS: every library builds for iOS (UIKit paths compile only there)"
# StoicSealed and StoicSealedKeychain are empty without their trait, which
# xcodebuild cannot enable, so they are built for iOS with SwiftPM and the trait.
ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
swift build --traits Crypto --target StoicSealed --sdk "$ios_sdk" --triple arm64-apple-ios27.0 --build-path .build/ios-sealed
swift build --traits Crypto --target StoicSealedKeychain --sdk "$ios_sdk" --triple arm64-apple-ios27.0 --build-path .build/ios-sealed
for scheme in Stoic StoicTesting StoicJSON StoicSchema StoicSchemaTesting StoicFoundation StoicStore StoicSettings StoicHTTP StoicApple StoicUIKit StoicAppKit StoicObservability; do
    xcodebuild -quiet -scheme "$scheme" -destination 'generic/platform=iOS' \
        -derivedDataPath .build/ios build
done

step "documentation: DocC builds with no warnings, in every library (broken links, undocumented parameters)"
# Not here: StoicMacros, StoicSealed and StoicSealedKeychain, whose symbols exist only with the Macros
# and Crypto traits, which xcodebuild cannot enable. A symbol of another Stoic library is written as
# code, not as a ``link``: DocC resolves a link only inside the module it is
# building. StoicUIKit builds for iOS, where its code compiles.
docs=$(mktemp)
for scheme in Stoic StoicTesting StoicJSON StoicSchema StoicSchemaTesting StoicFoundation StoicStore StoicSettings \
    StoicHTTP StoicObservability StoicApple StoicAppKit StoicUIKit; do
    destination='platform=macOS'
    if [ "$scheme" = StoicUIKit ]; then destination='generic/platform=iOS'; fi
    xcodebuild docbuild -scheme "$scheme" -destination "$destination" -derivedDataPath .build/docs > "$docs" 2>&1 || {
        tail -30 "$docs"
        printf 'FAIL %s: docbuild failed\n' "$scheme"
        exit 1
    }
    warnings=$(grep -E "warning:" "$docs" | grep -v "(in target" | sort -u || true)
    if [ -n "$warnings" ]; then
        printf '%s\n' "$warnings"
        printf 'FAIL %s: DocC warnings\n' "$scheme"
        exit 1
    fi
    printf '  ok %s\n' "$scheme"
done
rm -f "$docs"

if [ "${1:-}" = "--stress" ]; then
    step "stress: every suite, up to 100 repetitions"
    swift test --maximum-repetitions 100 --repeat-until fail
fi

printf '\nAll checks passed.\n'
