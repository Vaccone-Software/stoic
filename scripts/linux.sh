#!/bin/sh
# Builds the libraries that do not depend on Apple frameworks, on Linux, so
# nothing Apple-only creeps into them unnoticed, then runs the package's
# tests there.
#
#   scripts/linux.sh            inside a Linux Swift toolchain (CI's container)
#   scripts/linux.sh --docker   from a Mac, in the swift:6.4 image
#
# `swift test` builds every target of the package, so Apple-only code
# (StoicAppKit, StoicUIKit, the Apple files of StoicApple) and its tests must
# compile to nothing here, and a test that needs an Apple facility is gated
# out where it is written. StoicSealed, StoicDownloads and StoicAttestation are
# built, and tested, with the `Attestation` trait, which enables `Crypto`:
# swift-crypto is BoringSSL here and swift-certificates its X.509, and both must
# compile and pass. Apple-only libraries (StoicAttestedHTTP, the App Attest parts
# of StoicApple) compile to nothing here, as StoicXPC does. The last step adopts
# the portable products from a fresh package (scripts/adoption.sh).
set -eu
cd "$(dirname "$0")/.."

targets="Stoic StoicTesting StoicJSON StoicSchema StoicSchemaTesting StoicFoundation StoicSettings StoicStore StoicSealed StoicObservability StoicHTTP StoicDownloads StoicTime StoicLive StoicAttestation"

if [ "${1:-}" = "--docker" ]; then
    exec docker run --rm -v "$PWD":/src -w /src swift:6.4 scripts/linux.sh
fi

for target in $targets; do
    printf '== %s\n' "$target"
    swift build --traits Attestation --build-path /tmp/stoic-linux-build --target "$target"
done
printf '\nAll Linux targets built.\n'

printf '\n== tests\n'
# One test per core, as in check.sh: left unbounded, every test of a bundle
# starts at once and the real-time waits of tests over their own work are
# starved by the crowd.
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-$(nproc)}
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH
swift test --traits Attestation --build-path /tmp/stoic-linux-build
printf '\nAll Linux tests passed.\n'

printf '\n== adoption\n'
scripts/adoption.sh
