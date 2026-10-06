#!/bin/bash
# Build and install Tour Guide on a connected iPhone (unlocked, developer mode on).
#   scripts/install_phone.sh [device-id]     (default: the first connected iPhone)
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
DEV=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /connected|available/ {print $3; exit}')}
[ -n "$DEV" ] || { echo "No connected iPhone (unlock it and plug it in)"; exit 1; }
xcodebuild -project TourGuide.xcodeproj -scheme TourGuide -configuration Debug -destination "generic/platform=iOS" \
  -allowProvisioningUpdates -derivedDataPath build/phone build | grep -E "error:|BUILD" || true
xcrun devicectl device install app --device "$DEV" build/phone/Build/Products/Debug-iphoneos/TourGuide.app
xcrun devicectl device process launch --device "$DEV" com.monkeybonez.tourguide
