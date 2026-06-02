#!/usr/bin/env bash
# Installer for the Claude Code status line.
#
# What it does:
#   1. Copies statusline-command.sh to ~/.claude/statusline-command.sh
#   2. Merges the `statusLine` block into ~/.claude/settings.json
#      (creating the file if missing, preserving everything else).
#
# Safe to re-run: it backs up settings.json first and only touches the
# `statusLine` key. Requires: bash 4.2+, jq.
#
# Usage:
#   ./install.sh                 # interval defaults to 60s (idle refresh)
#   REFRESH_INTERVAL=300 ./install.sh
set -euo pipefail

REFRESH_INTERVAL="${REFRESH_INTERVAL:-60}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline-command.sh"
SCRIPT_DST="$CLAUDE_DIR/statusline-command.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

command -v jq >/dev/null || { echo "error: jq is required (install it first)." >&2; exit 1; }
[ -f "$SCRIPT_SRC" ] || { echo "error: $SCRIPT_SRC not found." >&2; exit 1; }

mkdir -p "$CLAUDE_DIR"

echo "→ installing script to $SCRIPT_DST"
cp "$SCRIPT_SRC" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"

# The statusLine block we want to ensure is present.
block=$(jq -n --argjson ri "$REFRESH_INTERVAL" '{
  type: "command",
  command: "bash ~/.claude/statusline-command.sh",
  refreshInterval: $ri
}')

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  echo "→ backed up existing settings.json"
  tmp=$(mktemp)
  jq --argjson sl "$block" '.statusLine = $sl' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
else
  echo "→ creating $SETTINGS"
  jq -n --argjson sl "$block" '{statusLine: $sl}' > "$SETTINGS"
fi

echo "✓ done. Restart Claude Code (or just interact) to see the status line."
echo "  Test it now:  echo '{\"model\":{\"display_name\":\"Opus\"},\"context_window\":{\"used_percentage\":42}}' | bash \"$SCRIPT_DST\""
