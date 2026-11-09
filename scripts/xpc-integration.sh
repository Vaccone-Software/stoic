#!/bin/sh
# StoicXPC against real processes (design/25, Testing): an app and its bundled
# XPC service, built by SwiftPM from scripts/xpc-integration, assembled into an
# app bundle and signed ad hoc, then run. The app starts the service through
# launchd and checks the handshake, a payload, a cancelled call, a requested
# end, a crash mid-request, the service's watchdog, and a kill of a service
# that will not exit. Nothing is signalled but that service, and only
# through StoicXPC's own pid check. About a minute: launchd delays the restart
# of a service that lived under ten seconds, and each scenario ends one.
set -eu
cd "$(dirname "$0")/xpc-integration"

swift build -c release
bin=$(swift build -c release --show-bin-path)

app=out/IntegrationApp.app
service=$app/Contents/XPCServices/IntegrationService.xpc
rm -rf out
mkdir -p "$app/Contents/MacOS" "$service/Contents/MacOS"
cp "$bin/IntegrationApp" "$app/Contents/MacOS/IntegrationApp"
cp "$bin/IntegrationService" "$service/Contents/MacOS/IntegrationService"

plist() { # path, identifier, executable, package type, extra keys
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>$3</string>
<key>CFBundleName</key><string>$3</string>
<key>CFBundlePackageType</key><string>$4</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
$5
</dict></plist>
PLIST
}
plist "$app/Contents/Info.plist" com.stoic.xpc-integration IntegrationApp APPL ""
plist "$service/Contents/Info.plist" com.stoic.xpc-integration.service IntegrationService 'XPC!' \
    '<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>'
codesign --force --sign - "$service"
codesign --force --sign - "$app"

# The app exits on its own; the timeout is for a hang, and its services go
# with it (a bundled service does not outlive its client).
timeout 180 "$app/Contents/MacOS/IntegrationApp"
