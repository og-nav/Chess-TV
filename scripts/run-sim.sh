#!/bin/zsh
# Build, install and launch on the Apple TV 4K simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="Apple TV 4K (3rd generation)"
xcodegen generate --quiet
xcodebuild -project ChessTV.xcodeproj -scheme ChessTV -destination "platform=tvOS Simulator,name=$NAME" \
  -derivedDataPath DerivedData -quiet build CODE_SIGNING_ALLOWED=NO
UDID=$(xcrun simctl list devices available | grep "$NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator
APP=$(find DerivedData/Build/Products -name "ChessTV.app" -path "*appletvsimulator*" | head -1)
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --console-pty "$UDID" com.navin.chesstv "$@"
