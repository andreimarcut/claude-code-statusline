#!/usr/bin/env bash
# Top-level test runner for claude-code-statusline.
#
# Runs, in order:
#   1. The bash test suite          (tests/test-statusline.sh)
#   2. Static checks                (tests/test-lint.sh — bash -n + shellcheck)
#   3. The Rust unit tests          (cargo test, under native/)
#   4. Script↔binary parity check   (./parity-check.sh)
#
# Items 1–2 need only bash + jq. Items 3–4 need cargo (and build the native
# binary); if cargo is absent they are SKIPPED, not failed, so the bash tests
# still pass on a box without a Rust toolchain.
#
# Flags:
#   --bash-only   run only items 1–2 (skip cargo/parity entirely)
#
# Exit: 0 iff every executed (non-skipped) step passed.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_ONLY=0
[ "${1:-}" = "--bash-only" ] && BASH_ONLY=1

rc=0
declare -a SUMMARY=()

# run <label> <cmd...> — run a step, record PASS/FAIL, keep going.
run() {
  local label="$1"; shift
  echo
  echo "════════════════════════════════════════════════════════════"
  echo "▶ $label"
  echo "════════════════════════════════════════════════════════════"
  if "$@"; then
    SUMMARY+=("PASS  $label")
  else
    SUMMARY+=("FAIL  $label")
    rc=1
  fi
}

# skip <label> <reason>
skip() {
  echo
  echo "════════════════════════════════════════════════════════════"
  echo "⏭ SKIP $1 — $2"
  echo "════════════════════════════════════════════════════════════"
  SUMMARY+=("SKIP  $1 ($2)")
}

# ── 1. Bash test suite ───────────────────────────────────────────────
run "bash test suite (tests/test-statusline.sh)" bash "$HERE/tests/test-statusline.sh"

# ── 2. Static checks (bash -n + shellcheck) ──────────────────────────
run "static checks (tests/test-lint.sh)" bash "$HERE/tests/test-lint.sh"

# ── 3. Rust unit tests ───────────────────────────────────────────────
if [ "$BASH_ONLY" = 1 ]; then
  skip "cargo test (native/)" "--bash-only"
elif command -v cargo >/dev/null 2>&1; then
  run "cargo test (native/)" bash -c 'cd "$1" && cargo test --manifest-path native/Cargo.toml' _ "$HERE"
else
  skip "cargo test (native/)" "cargo not installed"
fi

# ── 4. Parity check (script ↔ native binary) ─────────────────────────
if [ "$BASH_ONLY" = 1 ]; then
  skip "parity-check.sh" "--bash-only"
elif command -v cargo >/dev/null 2>&1; then
  run "parity-check.sh" bash "$HERE/parity-check.sh"
else
  skip "parity-check.sh" "cargo not installed (needs the native binary)"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════"
echo "SUMMARY"
echo "════════════════════════════════════════════════════════════"
for s in "${SUMMARY[@]}"; do echo "  $s"; done
echo
[ "$rc" -eq 0 ] && echo "ALL EXECUTED STEPS PASSED" || echo "SOME STEPS FAILED"
exit "$rc"
