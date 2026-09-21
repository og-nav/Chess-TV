#!/bin/zsh
# Download the Stockfish 19 network into the app resources and verify its checksum prefix.
set -euo pipefail
cd "$(dirname "$0")/.."
NET=nn-1a298aa575a0.nnue
DEST=Apps/ChessTV/Resources/$NET
[ -f "$DEST" ] && { echo "already present"; exit 0; }
curl -sSL --fail -o "$DEST" "https://tests.stockfishchess.org/api/nn/$NET"
SUM=$(shasum -a 256 "$DEST" | cut -c1-12)
[ "$SUM" = "1a298aa575a0" ] || { echo "checksum mismatch: $SUM"; rm -f "$DEST"; exit 1; }
echo "fetched $NET"
