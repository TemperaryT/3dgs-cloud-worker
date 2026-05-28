#!/usr/bin/env bash
# serve-local.sh — Serve self-hosted SuperSplat on localhost only.
# IP-SAFE: bound to 127.0.0.1; no data leaves the machine.
#
# SuperSplat runs entirely in the browser (WebGL/WebGPU).
# Your PLY file is loaded from disk by the browser — nothing is uploaded.
#
# Usage:
#   bash tools/supersplat/serve-local.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SCRIPT_DIR/supersplat-src/dist"
PORT="${SUPERSPLAT_PORT:-8778}"

if [ ! -d "$DIST_DIR" ]; then
  echo "ERROR: dist/ not found at $DIST_DIR"
  echo "Run setup.sh first:  bash tools/supersplat/setup.sh"
  exit 1
fi

echo "========================================"
echo "  SuperSplat — local-only server"
echo "========================================"
echo ""
echo "  Open:  http://127.0.0.1:${PORT}/"
echo ""
echo "  IP-SAFE: bound to 127.0.0.1 only."
echo "  SuperSplat is entirely client-side — no data leaves this machine."
echo ""
echo "  Press Ctrl-C to stop."
echo ""

cd "$DIST_DIR"
exec python3 -m http.server --bind 127.0.0.1 "$PORT"
