#!/bin/zsh
# Run package tests on the host, then the app test bundle on the tvOS simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
for pkg in ChessCore ChessUI LichessKit EngineKit ImageryKit GameSessionKit FollowKit; do
  echo "== swift test: $pkg"
  (cd "Packages/$pkg" && swift test -q 2>&1 | tail -n 5)
done
xcodegen generate --quiet
SIM="platform=tvOS Simulator,name=Apple TV 4K (3rd generation)"
xcodebuild -project ChessTV.xcodeproj -scheme ChessTV -destination "$SIM" -derivedDataPath DerivedData -collect-test-diagnostics never -quiet test CODE_SIGNING_ALLOWED=NO
echo "tests ok"
