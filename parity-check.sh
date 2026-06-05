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
# Diff one envelope through both front-ends with a given template. An empty
# template forces the hardcoded path on both (immune to an inherited env var).
_cmp() { # <label> <template> <json>
  local a b
  a=$(printf '%s' "$3" | CLAUDE_STATUSLINE_THROTTLE=0 CLAUDE_STATUSLINE_TEMPLATE="$2" bash "$SH")
  b=$(printf '%s' "$3" | CLAUDE_STATUSLINE_TEMPLATE="$2" "$BIN")
  if [ "$a" = "$b" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "MISMATCH: $1"
    echo "  script: [$(printf '%s' "$a" | cat -v)]"
    echo "  binary: [$(printf '%s' "$b" | cat -v)]"
  fi
}
check()  { _cmp "$1" "" "$2"; }      # default-path case (hardcoded both sides)
checkt() { _cmp "$1" "$2" "$3"; }    # template-engine case

check "full"        '{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"/home/me/proj"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":11.55,"total_duration_ms":4560000},"rate_limits":{"five_hour":{"used_percentage":85,"resets_at":'"$((now+5400))"'},"seven_day":{"used_percentage":10}},"effort":{"level":"high"}}'
check "week-reset"  '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":'"$((now+300000))"'}}}'
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

# ── Template engine: the same custom templates must render identically ──
_full='{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"/home/me/proj"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":11.55,"total_duration_ms":4560000},"rate_limits":{"five_hour":{"used_percentage":85,"resets_at":'"$((now+5400))"'},"seven_day":{"used_percentage":10,"resets_at":'"$((now+300000))"'}},"effort":{"level":"high"}}'
checkt "tpl-min"      '{json.model.display_name:short} {json.cost.total_cost_usd:usd}' "$_full"
checkt "tpl-colors"   '{red}{json.effort.level}{reset} {fg256:208}x{reset} {rgb:1,2,3}y{reset} {#abcdef}z{reset} {bg_blue}b{reset} {bold}o{reset}' "$_full"
checkt "tpl-bars"     '{json.context_window.used_percentage:bar} {json.rate_limits.five_hour.used_percentage:bar} {json.rate_limits.seven_day.used_percentage:pct}' "$_full"
checkt "tpl-sep-on"   'a {sep} b' '{}'
checkt "tpl-sep-off"  '{json.nope.field} {sep} b' '{}'
checkt "tpl-collapse" 'a {json.nope.field} b' '{}'
checkt "tpl-group"    'x{?json.context_window.used_percentage} ctx {json.context_window.used_percentage:bar}{/}{?json.nope.x} hidden{/} y' "$_full"
checkt "tpl-rawfield" '+{json.cost.total_lines_added}/-{json.cost.total_lines_removed}' '{"cost":{"total_lines_added":156,"total_lines_removed":23}}'
checkt "tpl-multiline" '{json.model.display_name:short}\n{json.effort.level}' "$_full"
checkt "tpl-escapes"  '\e[1mA\e[0m \033[2mB\033[0m \x1b[3mC\x1b[0m ❤' '{}'
checkt "tpl-countdown" '{json.rate_limits.five_hour.resets_at:countdown}{json.rate_limits.seven_day.resets_at:countdown}' "$_full"
checkt "tpl-pct-plain" '{json.context_window.used_percentage:pct-plain}' "$_full"
checkt "tpl-familyver"  '{json.model.display_name:familyver}' "$_full"
checkt "tpl-familyver-bare" '{json.model.display_name:familyver}' '{"model":{"display_name":"Opus"}}'
checkt "tpl-ctxsize-1m"  '[{json.model.id:ctxsize}]' '{"model":{"id":"claude-opus-4-8[1m]"}}'
checkt "tpl-ctxsize-def" '[{json.model.id:ctxsize}]' '{}'
checkt "tpl-bgcolors"  '{bg256:200}o{reset} {bgrgb:10,20,30}p{reset} {bg#ff0080}q{reset}' '{}'
checkt "tpl-sep-dot"   'a {sep:dot} b' '{}'
checkt "tpl-sep-slash" 'a {sep:slash} b' '{}'
checkt "tpl-sep-space" 'a{sep:space}b' '{}'
checkt "tpl-esc-tab"   'x\ty' '{}'
checkt "tpl-esc-uni"   '♥' '{}'
checkt "tpl-esc-hibyte" '[\xC3][\303][\x80][\200]' '{}'
checkt "tpl-esc-surr"  '[\uD83D]' '{}'
checkt "tpl-bool"      'A{?json.x.y}B{json.x.y}C{/}D' '{"x":{"y":false}}'
checkt "tpl-bare-cond" '{?foo}FOUND{/}' '{"foo":"bar"}'
checkt "tpl-nl-value"  'A={json.a} B={json.b}' '{"a":"foo\nbar","b":"X"}'
checkt "tpl-cd-now"    '[{json.r.resets_at:countdown}]' '{"r":{"resets_at":'"$now"'}}'
checkt "tpl-inject"    'LEAK={json.nonexist // $ENV.HOME) | (.}' '{}'
# Containers (array/object) are empty in BOTH engines: {?path} false, text empty.
checkt "tpl-arr-text"  '[{json.x}]' '{"x":[1,2]}'
checkt "tpl-obj-cond"  '{?json.x}YES{/}NO' '{"x":{}}'
checkt "tpl-sec-cond"  '{?json.rate_limits}HAS{/}' '{"rate_limits":{"five_hour":{"used_percentage":20}}}'
# Whole-valued / exponent numbers normalize to integer form (matches node_text).
checkt "tpl-num-dot0"  '[{json.x}]' '{"x":42.0}'
checkt "tpl-num-exp"   '{json.x:pct-plain} [{json.x}]' '{"x":5e1}'
# Negative numerics render in both (Rust as_f64 + relaxed bash regex).
checkt "tpl-num-neg"   '{json.x:pct} {json.x:bar}' '{"x":-5}'
checkt "tpl-usd-neg"   '{json.c.total_cost_usd:usd}' '{"c":{"total_cost_usd":-3.5}}'
# Empty path / bare cond: no error, empty value / group absent (matches Rust).
checkt "tpl-empty-path" 'A{json.}B' '{}'
checkt "tpl-empty-cond" 'A{?}B{/}C' '{}'
# The default template, forced through the engine (trailing space dodges the
# exact-match short-circuit), must still match between front-ends.
_dt=$(sed -n "s/^DEFAULT_TEMPLATE='\(.*\)'\$/\1/p" "$SH")
checkt "tpl-default"  "$_dt " "$_full"
# Regression cases for the /code-review correctness fixes (must render identically):
checkt "tpl-scalar-index" 'A[{json.model.display_name.x}]B [{json.workspace.current_dir:basename}]' '{"model":{"display_name":"Sonnet"},"workspace":{"current_dir":"/t/proj"}}'  # F1: a path through a scalar must not blank the whole line
checkt "tpl-huge-num"     '{json.x:bar}|{json.x:pct}|{json.x:dur}' '{"x":9500000000000000000}'   # F2: out-of-range numeric → empty, no error
checkt "tpl-imax-num"     '{json.x:bar}' '{"x":9223372036854775807}'
checkt "tpl-usd-half1"    'C={json.cost.total_cost_usd:usd}' '{"cost":{"total_cost_usd":11.555}}'  # F4: half-cent rounding parity
checkt "tpl-usd-half2"    'C={json.cost.total_cost_usd:usd}' '{"cost":{"total_cost_usd":0.005}}'
checkt "tpl-usd-carry"    'C={json.cost.total_cost_usd:usd}' '{"cost":{"total_cost_usd":9.995}}'
checkt "tpl-usd-neg"      'C={json.cost.total_cost_usd:usd}' '{"cost":{"total_cost_usd":-3.567}}'

echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
