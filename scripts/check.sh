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

if [ "${1:-}" = "--stress" ]; then
    step "stress: every suite, up to 100 repetitions"
    swift test --maximum-repetitions 100 --repeat-until fail
fi

printf '\nAll checks passed.\n'
