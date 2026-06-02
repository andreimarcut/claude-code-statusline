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
    # Prefer the musl static target when it's installed AND the host is x86_64-Linux:
    # ~2.5x smaller binary and far fewer startup relocations than static glibc →
    # measurably faster spawn. The host check matters because the musl target can be
    # installed on a non-x86_64-Linux box (any dev who once cross-built for Linux) —
    # without it, macOS aborts the build mid-install and aarch64-Linux silently
    # installs an x86_64 ELF that fails with "exec format error" at runtime.
    # Falls back to the host target (e.g. macOS, aarch64-Linux, or a box without the
    # musl target), which is still statically linked on Linux. Add the target with:
    #   rustup target add x86_64-unknown-linux-musl
    target_flag=""
    bin_path="$HERE/native/target/release/claude-statusline"
    if [ "$(uname -sm)" = "Linux x86_64" ] && rustup target list --installed 2>/dev/null | grep -qx x86_64-unknown-linux-musl; then
      target_flag="--target x86_64-unknown-linux-musl"
      bin_path="$HERE/native/target/x86_64-unknown-linux-musl/release/claude-statusline"
      echo "→ building native binary (musl static target)…"
    else
      echo "→ building native binary (host target)…"
    fi
    # Run from the repo root so .cargo/config.toml (static linking) is found.
    ( cd "$HERE" && cargo build --release --manifest-path native/Cargo.toml $target_flag )
    cp "$bin_path" "$BIN_DST"
    chmod +x "$BIN_DST"
    # Guardrail: the native path's whole point is no dynamic linker at startup.
    # Warn loudly if a build regressed to dynamic linking (e.g. crt-static was lost
    # because the build didn't run from the repo root, so .cargo/config.toml was
    # not picked up). See parity-check.sh for the hard (CI) version of this check.
    if command -v file >/dev/null && file -b "$BIN_DST" | grep -qi 'dynamically linked'; then
      echo "! WARNING: native binary is DYNAMICALLY linked (expected static) — startup will be slower." >&2
      echo "  Check .cargo/config.toml (-C target-feature=+crt-static) and build from the repo root." >&2
    fi
    # Use an ABSOLUTE path (no leading '~') so Claude Code can execve the binary
    # directly instead of routing it through a shell. The kernel does not expand
    # '~', so a '~'-prefixed command is not execve-able and forces a /bin/sh
    # wrapper (~0.7–0.9 ms of bash startup — far larger than the binary itself).
    command_str="$BIN_DST"
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
