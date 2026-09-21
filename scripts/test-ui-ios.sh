#!/bin/zsh
# The iPhone/iPad UI suite: every screen and control under fixtures, with frame-lag readings.
# Usage: scripts/test-ui-ios.sh [-only-testing:ChessTVMobileUITests/SomeClass]
set -euo pipefail
cd "$(dirname "$0")/.."
# One generate at a time, and a retry if the other platform's script regenerated under us.
until mkdir .xcodegen.lock 2>/dev/null; do sleep 1; done
xcodegen generate --quiet; rmdir .xcodegen.lock
SIM_ID="${IOS_SIM_ID:-B2DBBD77-A18F-4893-AABC-89E7563F91A4}"
RESULT="${UI_RESULT_BUNDLE:-DerivedData-iOS/ui-tests-$(date +%Y%m%d-%H%M%S).xcresult}"
run() { xcodebuild -project ChessTV.xcodeproj -scheme ChessTVMobileUITests -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath DerivedData-iOS -resultBundlePath "$RESULT" -parallel-testing-enabled NO -collect-test-diagnostics never -quiet "$@" test CODE_SIGNING_ALLOWED=NO; }
if ! run "$@" 2>&1 | tee /tmp/chesstv-ui-$$.log; then
  if grep -q "Unable to read project" /tmp/chesstv-ui-$$.log; then sleep 3; run "$@"; else exit 1; fi
fi
echo "ui tests ok · $RESULT"
