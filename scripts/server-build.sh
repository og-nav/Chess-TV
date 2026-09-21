#!/bin/zsh
# Local: scripts/server-build.sh [--release]
# Linux: scripts/server-build.sh --linux [linux/amd64|linux/arm64]
set -euo pipefail
cd "$(dirname "$0")/.."
PACKAGE="Server/follow-server"
if [[ "${1:-}" == "--linux" ]]; then
  command -v docker >/dev/null || { echo "Docker is required for Linux builds" >&2; exit 1; }
  PLATFORM="${2:-linux/amd64}"
  case "$PLATFORM" in linux/amd64|linux/arm64) ;; *) echo "Unsupported platform: $PLATFORM" >&2; exit 1 ;; esac
  IMAGE="chesstv-follow:local-${PLATFORM#linux/}"
  docker build --platform "$PLATFORM" -f Server/Dockerfile -t "$IMAGE" .
  CONTAINER=$(docker create --platform "$PLATFORM" "$IMAGE")
  trap 'docker rm "$CONTAINER" >/dev/null' EXIT
  mkdir -p "$PACKAGE/.build-linux/release"
  docker cp "$CONTAINER:/usr/local/bin/follow-server" "$PACKAGE/.build-linux/release/follow-server"
  echo "Built $IMAGE with matching Swift runtime; binary: $PACKAGE/.build-linux/release/follow-server"
  exit 0
fi
CONFIG=debug
[[ "${1:-}" == "--release" ]] && CONFIG=release
swift build --package-path "$PACKAGE" -c "$CONFIG" -j 2
