#!/usr/bin/env bash
# Build Cheeko Nav and install it on the plugged-in iPhone.
# With a free Apple account the app stops opening after 7 days: just run this again.
set -euo pipefail
cd "$(dirname "$0")/CheekoNav"

DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ && /physical/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
if [[ -z "$DEVICE" ]]; then
  echo "No iPhone found. Plug it in, unlock it, and tap Trust if asked." >&2
  exit 1
fi

xcodegen >/dev/null
xcodebuild -project CheekoNav.xcodeproj -scheme CheekoNav -destination "id=$DEVICE" \
  -derivedDataPath build -allowProvisioningUpdates -quiet build
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Debug-iphoneos/CheekoNav.app >/dev/null
xcrun devicectl device process launch --device "$DEVICE" com.diypet.cheekonav >/dev/null && echo "Cheeko Nav installed and opened."
