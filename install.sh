#!/usr/bin/env bash
# Installer for the Claude Code status line.
#
# What it does:
#   1. Installs the bash script to ~/.claude/statusline-command.sh (always —
#      it's the portable default and the fallback).
#   2. With --native (or NATIVE=1): also builds the Rust binary and points
#      Claude Code at it instead (faster + less RAM; see README "Native fast
#      path"). Requires cargo; falls back to the script if it's missing.
#   3. Merges the `statusLine` block into ~/.claude/settings.json (creating it
#      if missing, backing it up first, preserving every other key).
#
# Safe to re-run. Requires: bash 4.2+, jq. --native also needs cargo.
#
# Usage:
#   ./install.sh                      # script, idle refresh 60s
#   ./install.sh --native             # build + use the native binary
#   REFRESH_INTERVAL=300 ./install.sh
set -euo pipefail

REFRESH_INTERVAL="${REFRESH_INTERVAL:-60}"
NATIVE="${NATIVE:-0}"
[ "${1:-}" = "--native" ] && NATIVE=1

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$HERE/statusline-command.sh"
SCRIPT_DST="$CLAUDE_DIR/statusline-command.sh"
BIN_DST="$CLAUDE_DIR/claude-statusline"
SETTINGS="$CLAUDE_DIR/settings.json"

command -v jq >/dev/null || { echo "error: jq is required (install it first)." >&2; exit 1; }
[ -f "$SCRIPT_SRC" ] || { echo "error: $SCRIPT_SRC not found." >&2; exit 1; }
mkdir -p "$CLAUDE_DIR"

echo "→ installing script to $SCRIPT_DST"
cp "$SCRIPT_SRC" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"

# Default: Claude Code runs the script.
command_str="bash ~/.claude/statusline-command.sh"

if [ "$NATIVE" = 1 ]; then
  if command -v cargo >/dev/null; then
    echo "→ building native binary (cargo build --release)…"
    cargo build --release --manifest-path "$HERE/native/Cargo.toml"
    cp "$HERE/native/target/release/claude-statusline" "$BIN_DST"
    chmod +x "$BIN_DST"
    command_str="~/.claude/claude-statusline"
    echo "→ installed native binary to $BIN_DST"
  else
    echo "! cargo not found — skipping native build, using the bash script." >&2
  fi
fi

block=$(jq -n --arg cmd "$command_str" --argjson ri "$REFRESH_INTERVAL" \
  '{type:"command", command:$cmd, refreshInterval:$ri}')

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  echo "→ backed up existing settings.json"
  tmp=$(mktemp)
  jq --argjson sl "$block" '.statusLine = $sl' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
else
  echo "→ creating $SETTINGS"
  jq -n --argjson sl "$block" '{statusLine: $sl}' > "$SETTINGS"
fi

echo "✓ done — Claude Code will use: $command_str"
echo "  Restart Claude Code (or just interact) to see it."
