#!/bin/sh
# The one command that says whether Stoic is healthy.
#
#   scripts/check.sh            build, test, sanitizers, lint, API, allocations, macros, iOS, docs
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

step "build"
swift build

step "tests"
swift test

step "tests under Thread Sanitizer: the concurrency primitives (data races the model tests cannot see)"
# The suites that exercise shared mutable state across tasks: semaphore,
# channel, single-flight, TaskSlot, scopes, race/map, supervision, service
# graph, state machine, simulation, abandoning timeouts, the resilience
# policies and the idempotency key hedged attempts read at once. A few minutes: the instrumented build is separate from the one above.
swift test --sanitize=thread --filter 'Semaphore|Channel|SingleFlight|TaskSlot|Scope|RaceAndMap|Supervis|ServiceGraph|StateMachine|Simulation|Abandoning|Hedge|CircuitBreaker|RateLimiter|Bulkhead|AttemptKey'

step "tests under Address Sanitizer: every suite (memory errors the type system cannot rule out)"
# One test is skipped: it asserts a wall-clock bound that holds in a normal
# build and not under the sanitizer's several-fold slowdown. It runs, with
# its bound, in the plain test step above.
swift test --sanitize=address --skip openingTwentyThousandPendingEntriesIsFast

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

step "allocations: hot paths allocate no more than recorded (Benchmarks/allocations.json)"
# Time is reported, not gated (shared CI machines drift); allocations per
# call are close to deterministic. Fewer than recorded is reported so the
# record can be ratcheted down with --record.
(cd Benchmarks && swift run -c release StoicBenchmarks --check allocations.json)

step "macros (Macros trait): expansion tests, usage tests, schemas against their hand-written twins"
swift build --traits Macros
swift test --traits Macros --filter StoicMacros

step "macros: a consumer without the trait never fetches swift-syntax"
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
mkdir -p "$probe/Sources/App"
cat > "$probe/Package.swift" <<MANIFEST
// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "probe",
    platforms: [.macOS(.v27)],
    dependencies: [.package(path: "$PWD")],
    targets: [.executableTarget(name: "App", dependencies: [.product(name: "StoicSchema", package: "$(basename "$PWD")")])]
)
MANIFEST
echo 'import StoicSchema; print(Schema<Int>.int().node.expectation)' > "$probe/Sources/App/main.swift"
(cd "$probe" && swift build --cache-path "$probe/cache" >/dev/null)
if [ -d "$probe/.build/checkouts/swift-syntax" ] || [ -d "$probe/cache/repositories" ]; then
    echo "swift-syntax was fetched by a consumer that did not enable the Macros trait"
    exit 1
fi

step "iOS: every library builds for iOS (UIKit paths compile only there)"
for scheme in Stoic StoicTesting StoicJSON StoicSchema StoicSchemaTesting StoicStore StoicSettings StoicHTTP StoicApple StoicUIKit StoicAppKit StoicObservability; do
    xcodebuild -quiet -scheme "$scheme" -destination 'generic/platform=iOS' \
        -derivedDataPath .build/ios build
done

step "documentation: DocC builds with no warnings (broken links, undocumented parameters)"
warnings=$(xcodebuild docbuild -scheme Stoic -destination 'platform=macOS' -derivedDataPath .build/docs 2>&1 \
    | grep -E "warning:" | grep -v "(in target" | sort -u || true)
if [ -n "$warnings" ]; then
    printf '%s\n' "$warnings"
    exit 1
fi

if [ "${1:-}" = "--stress" ]; then
    step "stress: every suite, up to 100 repetitions"
    swift test --maximum-repetitions 100 --repeat-until fail
fi

printf '\nAll checks passed.\n'
