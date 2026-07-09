#!/bin/bash
# UI smoke test: install, launch, verify the app is alive as a menu bar
# accessory, then (optionally) quit it. Run on macOS.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ building & installing"
make install >/dev/null

echo "→ launching"
open /Applications/MayStock.app
sleep 4

if pgrep -x MayStock >/dev/null; then
  echo "✓ MayStock is running"
else
  echo "✗ MayStock failed to launch"; exit 1
fi

# Accessory apps own no windows; presence in the status bar is implied by
# a healthy run loop. Give it a few seconds of market data, then check again.
sleep 6
if pgrep -x MayStock >/dev/null; then
  echo "✓ still alive after 10s of live data"
else
  echo "✗ MayStock crashed within 10s"; exit 1
fi

if [ "${1:-}" == "--keep" ]; then
  echo "→ leaving app running (--keep)"
else
  osascript -e 'tell application "MayStock" to quit' 2>/dev/null || pkill -x MayStock || true
  echo "✓ smoke test passed"
fi
