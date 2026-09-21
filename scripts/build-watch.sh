#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project ChessTV.xcodeproj -scheme ChessTVWatch -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath DerivedData-Watch -quiet build CODE_SIGNING_ALLOWED=NO
