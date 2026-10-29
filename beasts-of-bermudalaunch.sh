#!/bin/bash
# Merge AMP's Game.ini.amp sidecar into the live Game.ini, then exec the Linux server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
GAME_INI="$ROOT/WindowsServer/BeastsOfBermuda/Saved/Config/WindowsServer/Game.ini"
SCRIPT="$ROOT/beasts-of-bermuda-preserve-game-ini.py"
SERVER="$ROOT/LinuxServer/BeastsOfBermuda/Binaries/Linux/BeastsOfBermudaServer"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -f "${GAME_INI}.amp" ]; then
        break
    fi
    sleep 0.2
done
if [ -f "$SCRIPT" ]; then
    python3 "$SCRIPT" --game-ini "$GAME_INI" --keep 10
fi
exec "$SERVER" "$@"
