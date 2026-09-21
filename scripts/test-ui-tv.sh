#!/bin/zsh
# The Apple TV UI suite: every screen and control under fixtures, walked with the remote.
# Usage: scripts/test-ui-tv.sh [-only-testing:ChessTVUITests/SomeClass]
set -euo pipefail
cd "$(dirname "$0")/.."
# One generate at a time, and a retry if the other platform's script regenerated under us.
until mkdir .xcodegen.lock 2>/dev/null; do sleep 1; done
xcodegen generate --quiet; rmdir .xcodegen.lock
TV_SIM_ID="${TV_SIM_ID:-695F6B35-F349-4616-87A3-3B0F73887F84}"
RESULT="${UI_RESULT_BUNDLE:-DerivedData/ui-tests-$(date +%Y%m%d-%H%M%S).xcresult}"
run() { xcodebuild -project ChessTV.xcodeproj -scheme ChessTVUITests -destination "platform=tvOS Simulator,id=$TV_SIM_ID" \
  -derivedDataPath DerivedData -resultBundlePath "$RESULT" -parallel-testing-enabled NO -collect-test-diagnostics never -quiet "$@" test CODE_SIGNING_ALLOWED=NO; }
# "$@" is forwarded, so a -only-testing: argument reaches xcodebuild ahead of `test`, which is
# where it has to be or it is dropped in silence. (It used to be dropped here instead, so asking
# for one class quietly ran all forty-eight.)
if ! run "$@" 2>&1 | tee /tmp/chesstv-ui-$$.log; then
  if grep -q "Unable to read project" /tmp/chesstv-ui-$$.log; then sleep 3; run "$@"; else exit 1; fi
fi
echo "ui tests ok · $RESULT"
