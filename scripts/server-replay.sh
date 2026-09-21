#!/bin/zsh
# Run the watcher over a recorded PGN stream with APNs stubbed, and print the pushes it would
# have sent, one JSON object per line. No network, no database file, no device.
#
#   scripts/server-replay.sh
#   scripts/server-replay.sh <round.pgn> <round.json> [seed.json]
#
# The seed file is optional and looks like:
#   { "follows": [ { "target": {"kind":"tournament","tourId":"L2ydImaD"}, "alerts": {"tournament":["gameResults"]} } ] }
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURES="Server/follow-server/Tests/FollowServerTests/Fixtures"
PGN="${1:-$FIXTURES/stream-round-22.pgn}"
ROUND="${2:-$FIXTURES/replay-round.json}"

(cd Server/follow-server && swift build -c debug >/dev/null)
BIN="Server/follow-server/.build/debug/follow-server"

if [[ -n "${3:-}" ]]; then
  "$BIN" --replay "$PGN" --round "$ROUND" --seed "$3"
else
  "$BIN" --replay "$PGN" --round "$ROUND"
fi
