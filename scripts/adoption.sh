#!/bin/sh
# Adopts Stoic the way an app does: a fresh package, outside this one, that
# depends on it by path and imports every library product. It proves the
# products are consumable from outside (nothing they expose needs a module
# the app cannot import), and that adopting them costs nothing else: with no
# traits enabled, resolution must fetch no remote package at all, because
# swift-syntax, swift-log and swift-metrics arrive only with the traits that
# use them.
#
#   scripts/adoption.sh            the libraries for this platform
#
# On Linux it adopts the portable libraries only. scripts/check.sh and
# scripts/linux.sh run it.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"

portable="Stoic StoicTesting StoicJSON StoicSchema StoicSchemaTesting StoicFoundation StoicStore StoicSettings StoicObservability StoicHTTP"
apple="StoicApple StoicAppKit StoicUIKit"
case "$(uname -s)" in
    Darwin) products="$portable $apple" ;;
    *) products="$portable" ;;
esac

# A path dependency's identity is its directory's name, not the manifest's.
identity="$(basename "$root")"

work="$(mktemp -d "${TMPDIR:-/tmp}/stoic-adoption.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/App"

dependencies=""
imports=""
count=0
for product in $products; do
    dependencies="$dependencies .product(name: \"$product\", package: \"$identity\"),"
    imports="${imports}import $product
"
    count=$((count + 1))
done

cat > "$work/Package.swift" <<EOF
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "adopter",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    dependencies: [.package(path: "$root")],
    targets: [.executableTarget(name: "App", dependencies: [$dependencies])]
)
EOF
printf '%s\n' "$imports" > "$work/Sources/App/main.swift"

cd "$work"
swift package resolve
# A path dependency is never pinned, so any pin is a remote package that
# adopting Stoic fetched.
if [ -f Package.resolved ] && grep -q '"identity"' Package.resolved; then
    echo "error: adopting Stoic without traits fetched remote packages:" >&2
    grep '"identity"' Package.resolved >&2
    exit 1
fi
if [ -n "$(ls -A .build/checkouts 2>/dev/null)" ]; then
    echo "error: adopting Stoic without traits checked out:" "$(ls .build/checkouts)" >&2
    exit 1
fi
# Built and linked, not run: the test-support libraries link Swift Testing,
# which a plain executable has no runtime path to.
swift build
echo "adopted $count Stoic libraries with no traits: nothing fetched, everything built"
