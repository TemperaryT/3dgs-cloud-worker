#!/usr/bin/env bash
# setup.sh — Self-host PlayCanvas SuperSplat fully locally.
# IP-SAFE: no data leaves the machine. SuperSplat runs entirely client-side.
#
# Usage:
#   cd tools/supersplat
#   bash setup.sh
#
# After setup, run:
#   bash serve-local.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/supersplat-src"
REPO_URL="https://github.com/playcanvas/supersplat"

echo "========================================"
echo "  SuperSplat local setup"
echo "========================================"

# ---- Check for git ----
if ! command -v git &>/dev/null; then
  echo "ERROR: git not found. Install with:"
  echo "  sudo apt install git"
  exit 1
fi

# ---- Check for npm / Node ----
if ! command -v npm &>/dev/null; then
  echo "ERROR: npm not found."
  echo ""
  echo "Install Node.js + npm via nvm (recommended):"
  echo "  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash"
  echo "  source ~/.bashrc   # or restart your shell"
  echo "  nvm install --lts"
  echo ""
  echo "Or via apt (older version but works):"
  echo "  sudo apt update && sudo apt install -y nodejs npm"
  exit 1
fi

NODE_VER=$(node --version 2>/dev/null || echo "unknown")
NPM_VER=$(npm --version 2>/dev/null || echo "unknown")
echo "  Node: $NODE_VER   npm: $NPM_VER"

# ---- Clone or update ----
if [ -d "$REPO_DIR/.git" ]; then
  echo ""
  echo "Repo already cloned at $REPO_DIR — pulling latest …"
  git -C "$REPO_DIR" pull --ff-only
else
  echo ""
  echo "Cloning $REPO_URL …"
  git clone "$REPO_URL" "$REPO_DIR"
fi

# ---- Install dependencies ----
echo ""
echo "Installing npm dependencies (this may take a minute) …"
cd "$REPO_DIR"
npm install

# ---- Build ----
echo ""
echo "Building SuperSplat …"
npm run build

# ---- Verify dist ----
if [ ! -d "$REPO_DIR/dist" ]; then
  echo ""
  echo "ERROR: build completed but dist/ directory was not created."
  echo "Check the output above for build errors."
  exit 1
fi

echo ""
echo "========================================"
echo "  Build complete!"
echo "  dist/ is at: $REPO_DIR/dist"
echo ""
echo "  Start the local server:"
echo "    bash $SCRIPT_DIR/serve-local.sh"
echo "========================================"
