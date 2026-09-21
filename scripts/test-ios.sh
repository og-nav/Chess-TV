#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
SIM_ID="${IOS_SIM_ID:-B2DBBD77-A18F-4893-AABC-89E7563F91A4}"
xcodebuild -project ChessTV.xcodeproj -scheme ChessTVMobile -destination "platform=iOS Simulator,id=$SIM_ID" \
  -parallel-testing-enabled NO -derivedDataPath DerivedData-iOS -collect-test-diagnostics never -quiet test CODE_SIGNING_ALLOWED=NO
