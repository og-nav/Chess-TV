#!/bin/zsh
# Build signed for the physical Apple TV and install it. The TV must be paired in Xcode (Devices window).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project ChessTV.xcodeproj -scheme ChessTV -destination 'generic/platform=tvOS' \
  -derivedDataPath DerivedData -quiet -allowProvisioningUpdates build
APP=$(find DerivedData/Build/Products -name "ChessTV.app" -path "*appletvos*" | head -1)
DEV=${1:-$(xcrun devicectl list devices 2>/dev/null | grep -i "apple tv" | head -1 | awk '{print $NF}')}
[ -n "$DEV" ] || { echo "No Apple TV found. Pass its identifier from: xcrun devicectl list devices"; exit 1; }
xcrun devicectl device install app --device "$DEV" "$APP"
xcrun devicectl device process launch --device "$DEV" com.navin.chesstv
