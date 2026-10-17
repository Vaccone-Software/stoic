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
#
# A second adoption enables the Crypto trait and uses StoicSealed for real
# (on Apple platforms with StoicSealedKeychain's adapter, built on a secret
# store, and the line design/24 shows for it, taken from that document so it
# cannot drift): swift-crypto must resolve, and nothing else may be fetched
# with it.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"

portable="Stoic StoicTesting StoicJSON StoicSchema StoicSchemaTesting StoicFoundation StoicStore StoicSettings StoicSealed StoicObservability StoicHTTP StoicDownloads"
apple="StoicApple StoicAppKit StoicUIKit StoicSealedKeychain"
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

# The Crypto trait: StoicSealed is an empty module above (the trait is what
# brings swift-crypto), so adopt it again with the trait on, build and run it.
crypto="$(mktemp -d "${TMPDIR:-/tmp}/stoic-adoption-crypto.XXXXXX")"
trap 'rm -rf "$work" "$crypto"' EXIT
mkdir -p "$crypto/Sources/App"
products='.product(name: "StoicSealed", package: "'"$identity"'"),'
case "$(uname -s)" in
    Darwin) products="$products .product(name: \"StoicSealedKeychain\", package: \"$identity\"), .product(name: \"StoicApple\", package: \"$identity\")," ;;
esac
cat > "$crypto/Package.swift" <<EOF
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "adopter-crypto",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    dependencies: [.package(path: "$root", traits: ["Crypto"])],
    targets: [.executableTarget(name: "App", dependencies: [$products])]
)
EOF
cat > "$crypto/Sources/App/main.swift" <<'EOF'
import Foundation
import StoicSealed

let directory = NSTemporaryDirectory() + "stoic-adoption-" + UUID().uuidString
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: directory) }

let testCustody = makeCustody()
let ring = try Keyring.open(name: "adoption.keyring", custody: testCustody, ifMissing: .create).keyring
let context = SealContext("adoption.note", "1")
let file = SealedFile(keyring: ring)
try file.write(Array("sealed".utf8), to: directory + "/note", context: context)
guard try file.read(directory + "/note", context: context) == Array("sealed".utf8) else { fatalError("a sealed file did not read back") }
let log = try SealedJournal.open(at: directory + "/log", context: context, keyring: ring)
try log.append(Array("record".utf8))
try log.compact(snapshot: Array("folded".utf8), rotatingKey: true)
guard try log.replay().snapshot?.bytes == Array("folded".utf8) else { fatalError("a sealed journal did not compact") }
print("adopted StoicSealed with the Crypto trait: sealed, opened and rotated")
EOF
case "$(uname -s)" in
    Darwin)
        # The line design/24 and docs/Adopting.md show for the Keychain, verbatim
        # from the document, so what they tell an app to write stays true. It
        # builds a custody over `KeychainSecretStore(service:)`, which touches no
        # keychain until it is asked for an item, so it is only compiled here.
        line="$(grep -m1 '^let custody = SecretStoreCustody(' "$root/design/24-sealed-storage.md" || true)"
        if [ -z "$line" ]; then
            echo "error: the SecretStoreCustody line was not found in design/24-sealed-storage.md" >&2
            exit 1
        fi
        {
            printf 'import StoicApple\nimport StoicSealed\nimport StoicSealedKeychain\n\n'
            printf '%s\n' "$line"
            printf '\n/// The documented custody, as the library type it is.\nfunc documentedCustody() -> any KeyCustody { custody }\n'
        } > "$crypto/Sources/App/Documented.swift"
        cat > "$crypto/Sources/App/Custody.swift" <<'EOF'
import StoicApple
import StoicSealed
import StoicSealedKeychain

/// The adapter over an in-memory secret store: no Keychain is touched.
func makeCustody() -> any KeyCustody { SecretStoreCustody(InMemorySecretStore()) }
EOF
        ;;
    *)
        cat > "$crypto/Sources/App/Custody.swift" <<'EOF'
import StoicSealed

func makeCustody() -> any KeyCustody { InMemoryKeyCustody() }
EOF
        ;;
esac

cd "$crypto"
swift package resolve
if [ ! -f Package.resolved ] || ! grep -q '"identity" : "swift-crypto"' Package.resolved; then
    echo "error: adopting StoicSealed with the Crypto trait did not resolve swift-crypto" >&2
    exit 1
fi
extra="$(grep '"identity"' Package.resolved | grep -v -e swift-crypto -e swift-asn1 || true)"
if [ -n "$extra" ]; then
    echo "error: the Crypto trait fetched more than swift-crypto:" >&2
    printf '%s\n' "$extra" >&2
    exit 1
fi
swift run App
echo "adopted StoicSealed with the Crypto trait: swift-crypto fetched, nothing else"
