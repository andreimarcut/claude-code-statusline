#!/usr/bin/env bash
# Verify the native binary (native/) renders byte-identically to the bash
# script across a battery of envelopes. Builds the binary if needed.
# Exits non-zero on any mismatch.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$HERE/statusline-command.sh"
# Override with BIN=<path> to check a different artifact (e.g. the musl build).
BIN="${BIN:-$HERE/native/target/release/claude-statusline}"

command -v jq >/dev/null   || { echo "need jq"; exit 1; }
command -v cargo >/dev/null || { echo "need cargo"; exit 1; }
if [ ! -x "$BIN" ]; then
  # Build to match $BIN. A BIN like .../target/<triple>/release/claude-statusline
  # implies a cross-target build (e.g. the musl artifact); derive --target from the
  # path so the documented `BIN=…/x86_64-unknown-linux-musl/… ./parity-check.sh`
  # workflow builds the right thing instead of the default host/glibc binary.
  tgt=""
  case "$BIN" in
    */target/*/release/*) triple="${BIN#*/target/}"; tgt="--target ${triple%%/release/*}" ;;
  esac
  ( cd "$HERE" && cargo build --release --manifest-path native/Cargo.toml $tgt >/dev/null )
fi
[ -x "$BIN" ] || { echo "error: $BIN not found after build" >&2; exit 1; }

# Guardrail: the native binary must be statically linked — having no dynamic
# linker at startup is its core performance property. Fail loudly if a build ever
# regresses to dynamic linking (e.g. crt-static lost / built from the wrong CWD).
if command -v file >/dev/null && file -b "$BIN" | grep -qi 'dynamically linked'; then
  echo "FAIL: $BIN is dynamically linked (expected statically linked)." >&2
  echo "  Fix: build from the repo root so .cargo/config.toml (+crt-static) applies." >&2
  exit 1
fi

now=$(date +%s); pass=0; fail=0
check() { # <label> <json>
  local a b
  a=$(printf '%s' "$2" | CLAUDE_STATUSLINE_THROTTLE=0 bash "$SH")
  b=$(printf '%s' "$2" | "$BIN")
  if [ "$a" = "$b" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "MISMATCH: $1"
    echo "  script: [$(printf '%s' "$a" | cat -v)]"
    echo "  binary: [$(printf '%s' "$b" | cat -v)]"
  fi
}

check "full"        '{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"/home/me/proj"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":11.55,"total_duration_ms":4560000},"rate_limits":{"five_hour":{"used_percentage":85,"resets_at":'"$((now+5400))"'},"seven_day":{"used_percentage":10}},"effort":{"level":"high"}}'
check "minimal"     '{"model":{"display_name":"Sonnet"},"context_window":{"used_percentage":3}}'
check "empty"       '{}'
check "no-effort"   '{"model":{"display_name":"Claude Haiku 4.5"},"workspace":{"current_dir":"/a/b/c"},"context_window":{"used_percentage":50}}'
check "sonnet"      '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":7},"rate_limits":{"five_hour":{"used_percentage":31,"resets_at":'"$((now+200))"'},"seven_day":{"used_percentage":10},"seven_day_sonnet":{"used_percentage":0}}}'
check "ctx0"        '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":0}}'
check "ctx100"      '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":100}}'
check "pct-float"   '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.9},"cost":{"total_cost_usd":0.08,"total_duration_ms":7000}}'
check "reset-past"  '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":'"$((now-100))"'}}}'
check "reset-min"   '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":'"$((now+90))"'}}}'
check "dur-hr"      '{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":7380000}}'
check "unknown-mdl" '{"model":{"display_name":"GPT-Foo Bar"},"context_window":{"used_percentage":12}}'
check "nested-cw"   '{"model":{"display_name":"Opus"},"context_window":{"current_usage":{"input_tokens":5},"used_percentage":63},"rate_limits":{"five_hour":{"used_percentage":77,"resets_at":'"$((now+3700))"'}}}'
check "no-model"    '{"context_window":{"used_percentage":5}}'

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
