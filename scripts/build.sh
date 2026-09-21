#!/bin/zsh
# Build the app for the tvOS simulator. Regenerates the Xcode project first.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project ChessTV.xcodeproj -scheme ChessTV -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath DerivedData -quiet build CODE_SIGNING_ALLOWED=NO
echo "build ok"
