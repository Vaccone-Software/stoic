#!/bin/sh
# The one command that says whether Stoic is healthy.
#
#   scripts/check.sh            build, test, lint tests, self-lint, macros
#   scripts/check.sh --stress   … and every suite 100 times
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

step "lint rule tests (Lint trait)"
swift test --traits Lint --filter StoicLintCoreTests

step "self-lint"
swift run --traits Lint stoic-lint Sources Plugins Package.swift

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
for scheme in Stoic StoicTesting StoicJSON StoicSchema StoicSchemaTesting StoicStore StoicSettings StoicApple StoicUIKit StoicAppKit StoicObservability; do
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
