#!/usr/bin/env bash
# =============================================================================
# aicontainer install.sh — host-side bootstrap
# =============================================================================
# Installs the `aic` CLI to ~/.local/bin. Assumes this script lives in a
# checkout of stefanoginella/aicontainer (typically cloned to ~/.aicontainer).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${AIC_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$BIN_DIR"
ln -sf "$SCRIPT_DIR/aic" "$BIN_DIR/aic"
chmod +x "$SCRIPT_DIR/aic"

echo "aic: installed → $BIN_DIR/aic (symlink to $SCRIPT_DIR/aic)"

if ! command -v aic >/dev/null 2>&1; then
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "aic: add $BIN_DIR to PATH, e.g.:"
       echo "    echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc" ;;
  esac
fi

if ! command -v devcontainer >/dev/null 2>&1; then
  echo "aic: warning — devcontainer CLI not found. Install with:"
  echo "    npm install -g @devcontainers/cli"
fi

if ! docker info >/dev/null 2>&1; then
  echo "aic: warning — Docker doesn't appear to be running. Start Docker Desktop / OrbStack / Colima first."
fi

echo "aic: done. Try 'aic help'."
