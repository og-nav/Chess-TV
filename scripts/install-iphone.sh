#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE_ID="${IOS_DEVICE_ID:?Set IOS_DEVICE_ID from xcrun devicectl list devices}"
xcodegen generate --quiet
xcodebuild -project ChessTV.xcodeproj -scheme ChessTVMobile -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath DerivedData-Device -allowProvisioningUpdates -quiet build
xcrun devicectl device install app --device "$DEVICE_ID" DerivedData-Device/Build/Products/Debug-iphoneos/ChessTVMobile.app
xcrun devicectl device process launch --device "$DEVICE_ID" com.navin.chesstv
