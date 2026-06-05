#!/usr/bin/env bash
# Exhaustive bash↔native PARITY matrix + fuzz.
#
# The two engines (statusline-command.sh and native/src/lib.rs) must render
# BYTE-IDENTICAL output for every template+envelope, and neither may error
# (bash under `set -u`) or panic (Rust). The hand-written batteries pin exact
# output for representative cases; THIS file blankets the input space:
#   - every {field × format} combination over fields of every JSON type,
#   - every color/style token (named/bright/bg/256/rgb/hex/style),
#   - a character torture set (unicode, emoji, combining, RTL, control,
#     quotes, backslashes, braces, $, backticks, 0x1f, newlines) both as
#     literal template text AND as field VALUES,
#   - structural combos (sep types, {^} boundary, nested/empty groups,
#     multi-line, adjacency/auto-collapse),
#   - malformed templates (unterminated, stray {/}, unknown fmt/color, deep nesting),
#   - a seeded random fuzz of token salad.
# For each case it asserts script-output == binary-output and that BOTH exit 0
# with empty stderr. It does NOT assert "correct" output (the exact-output
# batteries do that) — it proves the two implementations never diverge or crash.
#
# Run: ./tests/test-parity-matrix.sh   (or via ./run-tests.sh)
# Needs: bash 4.2+, jq, cargo (skips with a notice if the binary can't be built).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SH="$ROOT/statusline-command.sh"
BIN="${BIN:-$ROOT/native/target/release/claude-statusline}"

command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 2; }
if [ ! -x "$BIN" ]; then
  command -v cargo >/dev/null 2>&1 || { echo "SKIP: cargo not installed, no native binary to diff against"; exit 0; }
  ( cd "$ROOT" && cargo build --release --manifest-path native/Cargo.toml >/dev/null 2>&1 ) \
    || { echo "SKIP: native build failed"; exit 0; }
fi

total=0; fail=0; diffs=0; errs=0
AE=$(mktemp); BE=$(mktemp); trap 'rm -f "$AE" "$BE"' EXIT

# Compare one (template, envelope) across both engines. countdown depends on the
# wall clock each process reads itself, so retry once on mismatch to absorb a
# rare second/minute tick between the two spawns.
cmp_case() { # <name> <template> [envelope]
  local name="$1" tpl="$2" env="${3:-$ENV}" a b ac bc ae be
  a=$(printf '%s' "$env" | CLAUDE_STATUSLINE_THROTTLE=0 CLAUDE_STATUSLINE_TEMPLATE="$tpl" bash "$SH" 2>"$AE"); ac=$?
  b=$(printf '%s' "$env" | CLAUDE_STATUSLINE_TEMPLATE="$tpl" "$BIN" 2>"$BE"); bc=$?
  if [ "$a" != "$b" ] && [[ "$tpl" == *countdown* ]]; then
    a=$(printf '%s' "$env" | CLAUDE_STATUSLINE_THROTTLE=0 CLAUDE_STATUSLINE_TEMPLATE="$tpl" bash "$SH" 2>"$AE"); ac=$?
    b=$(printf '%s' "$env" | CLAUDE_STATUSLINE_TEMPLATE="$tpl" "$BIN" 2>"$BE"); bc=$?
  fi
  ae=$(<"$AE"); be=$(<"$BE")   # fork-free read (no `cat`)
  total=$((total+1))
  if [ "$a" != "$b" ]; then
    fail=$((fail+1)); diffs=$((diffs+1))
    if [ "$diffs" -le 25 ]; then
      printf 'DIFF  %-26s tpl=%q\n      sh=[%s]\n      bn=[%s]\n' "$name" "$tpl" "$(printf %s "$a"|cat -v)" "$(printf %s "$b"|cat -v)"
    fi
  elif [ "$ac" != 0 ] || [ -n "$ae" ] || [ "$bc" != 0 ] || [ -n "$be" ]; then
    fail=$((fail+1)); errs=$((errs+1))
    if [ "$errs" -le 25 ]; then
      printf 'ERROR %-26s tpl=%q  sh(exit=%s,err=%q) bn(exit=%s,err=%q)\n' "$name" "$tpl" "$ac" "$ae" "$bc" "$be"
    fi
  fi
}

# ── Rich base envelope: a field of (nearly) every JSON shape ──────────────────
ENV=$(jq -nc '{
  model:{display_name:"Claude Opus 4.8", id:"claude-opus-4-8"},
  effort:{level:"high"},
  workspace:{current_dir:"/home/me/the-proj", project_dir:"/home/me"},
  cwd:"/home/me/the-proj",
  context_window:{used_percentage:42, remaining_percentage:58},
  cost:{total_cost_usd:11.55, total_duration_ms:4560000, total_lines_added:156, total_lines_removed:23, total_api_duration_ms:2300},
  rate_limits:{five_hour:{used_percentage:85, resets_at:9999999999}, seven_day:{used_percentage:10, resets_at:9999999999}, seven_day_sonnet:{used_percentage:3}},
  version:"2.1.160", session_id:"abc-123", session_name:"my session",
  num_int:42, num_float:42.9, num_neg:-7, num_exp:5e1, num_zero:0, num_big:1234567890123,
  flag_true:true, flag_false:false, val_null:null, arr:[1,2,3], obj:{a:1},
  str_empty:"", str_uni:"café 中文 🎉", str_path:"/x/y/zed", str_spaces:"a   b"
}')

echo "== 1. field × format matrix =="
FIELDS=( model.display_name effort.level workspace.current_dir cwd \
  context_window.used_percentage cost.total_cost_usd cost.total_duration_ms \
  cost.total_lines_added rate_limits.five_hour.used_percentage \
  rate_limits.five_hour.resets_at rate_limits.__sonnet__.used_percentage \
  version session_name num_int num_float num_neg num_exp num_zero num_big \
  flag_true flag_false val_null arr obj str_empty str_uni str_path str_spaces nope.missing )
FORMATS=( text bar pct pct-plain dur countdown usd short basename folder effort )
for fld in "${FIELDS[@]}"; do
  for fmt in "${FORMATS[@]}"; do
    cmp_case "fld:${fld}:${fmt}" "[{json.${fld}:${fmt}}]"
  done
done

echo "== 2. every color / style token =="
COLORS=( reset bold dim italic underline blink reverse hidden strike \
  black red green yellow blue magenta cyan white \
  bright_black grey gray bright_red bright_green bright_yellow bright_blue bright_magenta bright_cyan bright_white \
  bg_black bg_red bg_green bg_yellow bg_blue bg_magenta bg_cyan bg_white \
  bg_bright_black bg_bright_red bg_bright_white \
  fg256:0 fg256:7 fg256:128 fg256:255 fg256:256 bg256:0 bg256:255 \
  rgb:0,0,0 rgb:255,255,255 rgb:10,20,30 rgb:256,0,0 bgrgb:1,2,3 \
  '#000000' '#ffffff' '#ff8800' '#fff' 'bg#abcdef' 'bg#zzzzzz' notacolor )
for c in "${COLORS[@]}"; do cmp_case "color:${c}" "{${c}}X{reset}"; done

echo "== 3. character torture (as literal AND as field value) =="
CHARS=( "é" "ñ" "中文" "日本語" "🎉" "👍🏽" "❤" "a̐" "‮rtl" "ascii" "" " " "a   b" \
  '"quote"' "'apos'" 'back\slash' 'dollar$x' 'tick`x`' 'pipe|x' 'semi;x' 'paren)x(' \
  'amp&x' 'brace{x}' 'lt<gt>' 'pct%d' 'star*' 'tilde~' 'at@' )
ci=0
for ch in "${CHARS[@]}"; do
  ci=$((ci+1))
  # as literal template text (braces escaped so they're not placeholders)
  lit=${ch//\{/\\\{}; lit=${lit//\}/\\\}}
  cmp_case "lit#${ci}" "pre-${lit}-post"
  # as a field VALUE (jq embeds it safely), rendered raw and via :text
  cenv=$(jq -nc --arg v "$ch" '{s:$v}')
  cmp_case "val#${ci}" "[{json.s}]" "$cenv"
  cmp_case "valtext#${ci}" "x{json.s:text}y" "$cenv"
done

echo "== 4. escape sequences =="
for e in '\t' '\n' '\e[1m' '\033[0m' '\x1b[31m' '\x41' 'A' 'é' '中' '\uD83D' '\uXYZ' '\xZZ' '\999' '\\' '\{' '\}' '\q'; do
  cmp_case "esc:${e}" "A${e}B"
done

echo "== 5. structural: seps / boundary / groups / multi-line / collapse =="
cmp_case "sep-bullet"  'a {sep} b'
cmp_case "sep-pipe"    'a {sep:pipe} b'
cmp_case "sep-dot"     'a {sep:dot} b'
cmp_case "sep-slash"   'a {sep:slash} b'
cmp_case "sep-space"   'a{sep:space}b'
cmp_case "sep-left0"   '{json.nope} {sep} b'
cmp_case "sep-right0"  'a {sep} {json.nope}'
cmp_case "sep-both0"   '{json.nope} {sep} {json.nope2}'
cmp_case "boundary"    'a {^} {sep} b'
cmp_case "collapse"    'a {json.nope} b'
cmp_case "collapse2"   'a   {json.nope}   b'
cmp_case "grp-present" 'x{?json.num_int} y {json.num_int} z{/} w'
cmp_case "grp-absent"  'x{?json.nope} y {json.nope} z{/} w'
cmp_case "grp-false"   'x{?json.flag_false}Y{json.flag_false}Z{/}W'
cmp_case "grp-null"    'x{?json.val_null}Y{/}Z'
cmp_case "grp-arr"     'x{?json.arr}Y{/}Z'
cmp_case "grp-obj"     'x{?json.obj}Y{/}Z'
cmp_case "grp-nested"  '{?json.num_int}A{?json.num_neg}B{json.num_neg}C{/}D{/}E'
cmp_case "grp-noprefix" '{?num_int}HIT{/}'
cmp_case "multiline"   '{json.model.display_name:short}\n{bright_white}ctx{reset} {json.context_window.used_percentage:bar}\nend'
cmp_case "adjacent"    '{json.num_int}{json.num_neg}{json.flag_true}'
cmp_case "default-eng" "$(sed -n "s/^DEFAULT_TEMPLATE='\(.*\)'\$/\1/p" "$SH") "  # trailing space forces engine

echo "== 6. malformed / adversarial templates =="
cmp_case "unterminated" 'a {json.model.display_name'
cmp_case "stray-close"  'a {/}{/} b'
cmp_case "empty-ph"     'a {} b'
cmp_case "empty-path"   'a {json.} b'
cmp_case "empty-cond"   'a {?}B{/} b'
cmp_case "unknown-fmt"  '{json.num_int:bogus}'
cmp_case "unknown-tok"  '{wat}{json.num_int:zzz}{octarine}'
cmp_case "deep-group"   '{?json.num_int}{?json.num_int}{?json.num_int}{?json.num_int}X{/}{/}{/}{/}'
cmp_case "bare-brace"   'a } b { c'
cmp_case "only-open"    '{{{{'
cmp_case "colon-noval"  '{json.num_int:}'
cmp_case "deep-path"    '{json.a.b.c.d.e.f.g}'

echo "== 7. jq-injection probes (must render empty, never leak/inject) =="
export PM_CANARY="LEAKED_SECRET"
for inj in '{json.x"]|env|.["PM_CANARY}' '{json.x")|input|("}' '{json.x|.["a"]}' '{json.$__loc__}' '{json.x);"}' '{json.x // env}'; do
  cmp_case "inj" "$inj"
  out=$(printf '%s' '{"x":1}' | CLAUDE_STATUSLINE_THROTTLE=0 CLAUDE_STATUSLINE_TEMPLATE="$inj" bash "$SH" 2>/dev/null)
  case "$out" in *LEAKED_SECRET*) echo "!! INJECTION LEAK via $inj"; fail=$((fail+1));; esac
done
unset PM_CANARY

echo "== 8. seeded random token-salad fuzz =="
RANDOM=12345
TOKENS=( '{json.num_int}' '{json.str_uni}' '{json.nope}' '{json.cost.total_cost_usd:usd}' \
  '{json.context_window.used_percentage:bar}' '{json.rate_limits.five_hour.resets_at:countdown}' \
  '{sep}' '{sep:pipe}' '{^}' '{?json.num_int}' '{?json.nope}' '{/}' '{red}' '{reset}' '{bold}' \
  '{fg256:200}' 'x' ' ' '\n' '\t' '\e[1m' 'é' '🎉' '"' '\\' '$' '{' '}' '%' )
for n in $(seq 1 150); do
  t=""; len=$(( RANDOM % 8 + 1 ))
  for ((j=0;j<len;j++)); do t+="${TOKENS[$((RANDOM % ${#TOKENS[@]}))]}"; done
  cmp_case "fuzz#${n}" "$t"
done

echo
echo "──────────────────────────────────────────"
printf 'PARITY MATRIX: %d cases, %d divergences, %d engine-errors, %d total failures\n' "$total" "$diffs" "$errs" "$fail"
[ "$fail" -eq 0 ]
