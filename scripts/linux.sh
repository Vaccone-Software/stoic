#!/bin/sh
# Builds the libraries that do not depend on Apple frameworks, on Linux, so
# nothing Apple-only creeps into them unnoticed.
#
#   scripts/linux.sh            inside a Linux Swift toolchain (CI's container)
#   scripts/linux.sh --docker   from a Mac, in the swift:6.4 image
#
# Build-only for now: `swift test` builds every test target, and the Apple
# libraries' tests do not build on Linux. StoicHTTP (URLSession) and the
# Apple libraries are left out on purpose.
set -eu
cd "$(dirname "$0")/.."

targets="Stoic StoicTesting StoicJSON StoicSchema StoicSchemaTesting StoicSettings StoicStore StoicObservability"

if [ "${1:-}" = "--docker" ]; then
    exec docker run --rm -v "$PWD":/src -w /src swift:6.4 scripts/linux.sh
fi

for target in $targets; do
    printf '== %s\n' "$target"
    swift build --build-path /tmp/stoic-linux-build --target "$target"
done
printf '\nAll Linux targets built.\n'
