#!/bin/zsh
# Reproducible feature regressions; server/device delivery and thermal soak are separate gates.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/LichessKit
swift test --package-path Packages/GameSessionKit
xcodegen generate --quiet
SIM_ID="${IOS_SIM_ID:-B2DBBD77-A18F-4893-AABC-89E7563F91A4}"
xcodebuild -project ChessTV.xcodeproj -scheme ChessTVMobile \
  -destination "platform=iOS Simulator,id=$SIM_ID" \
  -derivedDataPath DerivedData-FeatureStress -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -only-testing:ChessTVMobileTests/FollowQueueStressTests \
  -only-testing:ChessTVMobileTests/ActivityQueueStressTests \
  -only-testing:ChessTVMobileTests/NotificationCallbackTests \
  -only-testing:ChessTVMobileTests/WatchGameDetailTests \
  -only-testing:ChessTVMobileTests/WidgetRoutingTests \
  -only-testing:ChessTVMobileTests/MobileLifecyclePresentationTests \
  -quiet test CODE_SIGNING_ALLOWED=NO
