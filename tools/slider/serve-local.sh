#!/usr/bin/env bash
# serve-local.sh — Serve the wipe-slider on localhost only (IP-safe).
# Binds strictly to 127.0.0.1; never exposed to LAN or internet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${SLIDER_PORT:-8777}"

echo "========================================"
echo "  3DGS Wipe Slider — local-only server"
echo "========================================"
echo ""
echo "  Open:  http://127.0.0.1:${PORT}/index.html"
echo ""
echo "  IP-SAFE: bound to 127.0.0.1 only."
echo "  No data leaves this machine."
echo ""
echo "  Press Ctrl-C to stop."
echo ""

cd "$SCRIPT_DIR"
exec python3 -m http.server --bind 127.0.0.1 "$PORT"
