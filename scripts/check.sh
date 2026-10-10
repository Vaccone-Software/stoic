#!/bin/sh
# The one command that says whether Stoic is healthy.
#
#   scripts/check.sh            build, test, lint tests, self-lint
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

step "iOS: every library builds for iOS (UIKit paths compile only there)"
for scheme in Stoic StoicTesting StoicJSON StoicSchema StoicSchemaTesting StoicStore StoicApple StoicUIKit StoicAppKit StoicObservability; do
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
