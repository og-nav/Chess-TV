#!/bin/zsh
# Host tests, or source-only Linux tests without contaminating Mac SwiftPM caches.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--linux" ]]; then
  command -v docker >/dev/null || { echo "Docker is required for Linux tests" >&2; exit 1; }
  PLATFORM="${2:-linux/amd64}"
  case "$PLATFORM" in linux/amd64|linux/arm64) ;; *) echo "Unsupported platform: $PLATFORM" >&2; exit 1 ;; esac
  SOURCE=$(mktemp -d /tmp/chesstv-linux-tests.XXXXXX)
  trap 'rm -rf "$SOURCE"' EXIT
  tar --exclude=.build --exclude=.build-linux --exclude=.swiftpm --exclude='*.p8' -cf - \
    Packages/ChessCore Packages/FollowKit Server/follow-server | tar -xf - -C "$SOURCE"
  for PACKAGE in Packages/FollowKit Server/follow-server; do
    CACHE="chesstv-${PACKAGE:t}-${PLATFORM#linux/}"
    docker run --rm --platform "$PLATFORM" --memory 3g --cpus 1.5 \
      -v "$SOURCE:/src:ro" -v "$CACHE:/cache" -w "/src/$PACKAGE" swift:6.2-noble \
      swift test --scratch-path /cache -j 2
  done
  exit 0
fi
swift test --package-path Packages/FollowKit -j 2
swift test --package-path Server/follow-server -j 2
