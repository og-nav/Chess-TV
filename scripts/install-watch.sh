#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE_ID="${WATCH_DEVICE_ID:?Set WATCH_DEVICE_ID from xcrun devicectl list devices}"
xcodegen generate --quiet
xcodebuild -project ChessTV.xcodeproj -scheme ChessTVWatch -destination "platform=watchOS,id=$DEVICE_ID" \
  -derivedDataPath DerivedData-WatchDevice -allowProvisioningUpdates -quiet build
xcrun devicectl device install app --device "$DEVICE_ID" DerivedData-WatchDevice/Build/Products/Debug-watchos/ChessTVWatch.app
xcrun devicectl device process launch --device "$DEVICE_ID" com.navin.chesstv.watchkitapp
