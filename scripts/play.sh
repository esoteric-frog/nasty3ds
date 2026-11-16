#!/bin/zsh
# Builds the release app and starts the first game in the Nasty3DS games folder (or the file given).
set -euo pipefail
cd ${0:A:h:h}
swift build -c release 2>&1 | tail -1
GAME=${1:-$(ls ~/Library/Application\ Support/Nasty3DS/games/*.(cci|3ds|cxi|zcci)(N) | head -1)}
[[ -n "$GAME" ]] || { echo "No game file in ~/Library/Application Support/Nasty3DS/games/"; exit 1; }
exec .build/release/Nasty3DS "$GAME"
