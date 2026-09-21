#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: scripts/push-sim.sh Fixtures/push-move.apns" >&2
  exit 2
fi
xcrun simctl push "${IOS_SIM_ID:-B2DBBD77-A18F-4893-AABC-89E7563F91A4}" com.navin.chesstv "$1"
