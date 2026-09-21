#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-ios.sh
SIM_ID="${IOS_SIM_ID:-B2DBBD77-A18F-4893-AABC-89E7563F91A4}"
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_ID" -b
xcrun simctl install "$SIM_ID" DerivedData-iOS/Build/Products/Debug-iphonesimulator/ChessTVMobile.app
xcrun simctl launch "$SIM_ID" com.navin.chesstv "$@"
