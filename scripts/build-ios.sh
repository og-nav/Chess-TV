#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project ChessTV.xcodeproj -scheme ChessTVMobile -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData-iOS -quiet build CODE_SIGNING_ALLOWED=NO
