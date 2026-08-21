#!/bin/bash
# One-time setup: installs the BlackHole 2ch virtual audio driver via Homebrew.
# Run this yourself in Terminal (it needs your admin password) before first using GraphicEQ.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found. Install it from https://brew.sh first." >&2
    exit 1
fi

echo "Installing BlackHole 2ch (virtual audio driver)..."
brew install blackhole-2ch

echo
echo "Done. Restarting coreaudiod so the new device shows up..."
sudo killall -9 coreaudiod || true

echo
echo "Check System Settings > Sound > Output — you should now see 'BlackHole 2ch' listed."
