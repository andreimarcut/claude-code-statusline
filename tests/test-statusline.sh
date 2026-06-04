#!/usr/bin/env bash
# Test suite for the NON-Rust pieces of claude-code-statusline.
#
# Covers statusline-command.sh end-to-end by piping JSON envelopes through it
# (with CLAUDE_STATUSLINE_THROTTLE=0 so we exercise the FULL render path) and
# asserting on the rendered line. Also smoke-tests bench.sh and sanity-checks
# install.sh's jq merge in isolation (never touching the real ~/.claude).
#
# Run:  ./tests/test-statusline.sh          (or via ../run-tests.sh)
# Exit: 0 if every assertion passes, 1 otherwise.
#
# Requires: bash 4.2+, jq. No build, no cargo, nothing under native/.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/statusline-command.sh"
BENCH="$ROOT/bench.sh"
INSTALL="$ROOT/install.sh"

command -v jq >/dev/null || { echo "FATAL: jq is required to run these tests" >&2; exit 2; }
[ -r "$SCRIPT" ]         || { echo "FATAL: $SCRIPT not found" >&2; exit 2; }

# ── Tiny assert harness ──────────────────────────────────────────────
PASS=0; FAIL=0
FAILED_NAMES=()

# Print a clear PASS/FAIL line; bump counters.
_ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n' "$1"; }

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then _ok "$1"
  else _bad "$1"; printf '         expected: [%s]\n         actual:   [%s]\n' "$2" "$3"; fi
}

# assert_ne <name> <a> <b>  — passes when the two strings DIFFER
assert_ne() {
  if [ "$2" != "$3" ]; then _ok "$1"
  else _bad "$1"; printf '         both values equal (expected differ): [%s]\n' "$2"; fi
}

# assert_contains <name> <haystack> <needle>
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then _ok "$1"
  else _bad "$1"; printf '         missing substring: [%s]\n         in:                [%s]\n' "$3" "$2"; fi
}

# assert_not_contains <name> <haystack> <needle>
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then _ok "$1"
  else _bad "$1"; printf '         unexpected substring: [%s]\n         in:                   [%s]\n' "$3" "$2"; fi
}

# assert_match <name> <haystack> <ERE>  — passes if the regex matches.
# Used for time-relative output (reset countdown) where a few seconds of
# wall-clock drift between the test computing `now` and the script computing
# its own `now` makes an exact value flaky — we pin the FORMAT, not the value.
assert_match() {
  if [[ "$2" =~ $3 ]]; then _ok "$1"
  else _bad "$1"; printf '         regex did not match: [%s]\n         in:                  [%s]\n' "$3" "$2"; fi
}

# assert_true <name> <cmd...>  — passes if the command exits 0.
# The command's own stdout is discarded so only the ok/FAIL line shows.
assert_true() {
  local name="$1"; shift
  if "$@" >/dev/null; then _ok "$name"; else _bad "$name"; fi
}

# ── Helpers for driving the script ───────────────────────────────────
# Strip SGR color escapes so assertions read like the visible status line.
strip_sgr() { sed $'s/\033\\[[0-9;]*m//g'; }

# Render an envelope with the FULL render path (throttle disabled). The fields
# template is cleared so these exercise the default hardcoded path regardless of
# any inherited CLAUDE_STATUSLINE_FIELDS.
# Usage: render '<json>'  -> stdout = raw rendered line (with escapes)
render() { printf '%s' "$1" | CLAUDE_STATUSLINE_THROTTLE=0 CLAUDE_STATUSLINE_FIELDS= bash "$SCRIPT"; }

# Same, but with color escapes stripped (visible text only).
render_plain() { render "$1" | strip_sgr; }

# Render an envelope through a custom CLAUDE_STATUSLINE_FIELDS template.
# Usage: render_tpl '<template>' '<json>'
render_tpl() { printf '%s' "$2" | CLAUDE_STATUSLINE_THROTTLE=0 CLAUDE_STATUSLINE_FIELDS="$1" bash "$SCRIPT"; }
render_tpl_plain() { render_tpl "$1" "$2" | strip_sgr; }

NOW="$(printf '%(%s)T' -1)"

echo "== statusline-command.sh: model name shortening =="
assert_eq "Opus shortened to [Opus]" \
  "[Opus]" "$(render_plain '{"model":{"display_name":"Claude Opus 4.8"}}' | grep -o '^\[[^]]*\]')"
assert_eq "Sonnet shortened to [Sonnet]" \
  "[Sonnet]" "$(render_plain '{"model":{"display_name":"Claude Sonnet 4.6"}}' | grep -o '^\[[^]]*\]')"
assert_eq "Haiku shortened to [Haiku]" \
  "[Haiku]" "$(render_plain '{"model":{"display_name":"Claude Haiku 4.5"}}' | grep -o '^\[[^]]*\]')"
assert_eq "Unknown model uses first word" \
  "[GPT-Foo]" "$(render_plain '{"model":{"display_name":"GPT-Foo Bar"}}' | grep -o '^\[[^]]*\]')"
assert_eq "Missing model name renders [?]" \
  "[?]" "$(render_plain '{}' | grep -o '^\[[^]]*\]')"

echo "== effort coloring (present + color-coded) =="
# high/max -> bright red (91), medium -> yellow (93), low/other -> green (92).
assert_contains "high effort shown after model" "$(render_plain '{"model":{"display_name":"Opus"},"effort":{"level":"high"}}')" "[Opus] high"
assert_contains "high effort colored red (91)"   "$(render '{"model":{"display_name":"Opus"},"effort":{"level":"high"}}')"   $'\033[91mhigh'
assert_contains "max effort colored red (91)"    "$(render '{"model":{"display_name":"Opus"},"effort":{"level":"max"}}')"    $'\033[91mmax'
assert_contains "medium effort colored yellow (93)" "$(render '{"model":{"display_name":"Opus"},"effort":{"level":"medium"}}')" $'\033[93mmedium'
assert_contains "low effort colored green (92)"  "$(render '{"model":{"display_name":"Opus"},"effort":{"level":"low"}}')"    $'\033[92mlow'
assert_not_contains "no effort segment when absent" "$(render_plain '{"model":{"display_name":"Opus"}}')" "high"

echo "== folder basename =="
assert_contains "basename of workspace.current_dir" \
  "$(render_plain '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/home/me/projects/demo"}}')" "[demo]"
assert_contains "falls back to cwd basename" \
  "$(render_plain '{"model":{"display_name":"Opus"},"cwd":"/tmp/zzz"}')" "[zzz]"
# With neither current_dir nor cwd, the script uses $PWD's basename — non-empty.
nodir_out="$(render_plain '{"model":{"display_name":"Opus"}}')"
assert_contains "folder segment present even with no dir fields" "$nodir_out" "["

echo "== context bar + percentage =="
ctx42="$(render_plain '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42}}')"
assert_contains "ctx label present"        "$ctx42" "ctx"
assert_contains "ctx 42% shown"            "$ctx42" "42%"
assert_contains "ctx bar has fill + empty glyphs" "$ctx42" "██░░░"
assert_eq "ctx 0% bar all empty" \
  "ctx ░░░░░ 0%" "$(render_plain '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":0}}' | grep -o 'ctx .* 0%')"
assert_eq "ctx 100% bar all full" \
  "ctx █████ 100%" "$(render_plain '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":100}}' | grep -o 'ctx .* 100%')"
assert_contains "ctx float decimals stripped (42.9 -> 42%)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.9}}')" "42%"

echo "== 5h bar + reset countdown formatting =="
# `resets_at` is absolute; the script subtracts its OWN `now`. A few seconds of
# wall-clock drift elapse between this test computing an offset and the script
# computing `now`, so we recompute `now` fresh per render (minimizing drift) and
# assert the FORMAT via regex (and the leading unit) rather than an exact value.
now_5h="$(printf '%(%s)T' -1)"
five_h="$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":85,"resets_at":'"$((now_5h+9000))"'}}}')"
assert_contains "5h label present"   "$five_h" "5h"
assert_contains "5h percentage"      "$five_h" "85%"
assert_contains "5h bar glyphs"      "$five_h" "████░"
# 9000s ≈ 2h30m → countdown is "2h<minutes>m" (minutes may read 29 vs 30 under drift).
assert_match "reset countdown h+m format (9000s -> 2hXXm)" "$five_h" $'↻2h[0-9]+m'
now_5h="$(printf '%(%s)T' -1)"
# 200s → minutes-only branch (>=60s, <3600s) → "↻Nm" with no h/s.
assert_match "reset countdown minutes-only format (200s -> NXm)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":31,"resets_at":'"$((now_5h+200))"'}}}')" $'↻[0-9]+m( |$)'
now_5h="$(printf '%(%s)T' -1)"
# 45s offset → seconds branch (0<diff<60). A few seconds of drift keeps it 1..59.
assert_match "reset countdown seconds format (45s -> NNs)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":31,"resets_at":'"$((now_5h+45))"'}}}')" $'↻[0-9]+s'
now_5h="$(printf '%(%s)T' -1)"
assert_not_contains "no countdown when reset is in the past" \
  "$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":'"$((now_5h-100))"'}}}')" "↻"

echo "== weekly % (all-models) =="
wk="$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":10}}}')"
assert_contains "wk label present" "$wk" "wk"
assert_contains "wk 10% shown"     "$wk" "wk 10%"
# severity color: <50 green(92), <80 yellow(93), >=80 red(91)
assert_contains "wk 10% colored green (92)"  "$(render '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":10}}}')" $'\033[92m10%'
assert_contains "wk 55% colored yellow (93)" "$(render '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":55}}}')" $'\033[93m55%'
assert_contains "wk 90% colored red (91)"    "$(render '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":90}}}')" $'\033[91m90%'

echo "== weekly reset countdown (largest unit + measure) =="
# `seven_day.resets_at` is absolute; the script subtracts its OWN `now`. Pin the
# FORMAT (largest applicable unit + its measure), not the exact value, to avoid
# a few seconds of drift flaking the test. Offsets sit mid-bucket on purpose.
now_wk="$(printf '%(%s)T' -1)"
# ≥1 day → days+hours, "↻NdMh".
assert_match "week reset days+hours format (3.5d -> NdMh)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":'"$((now_wk+302400))"'}}}')" $'↻[0-9]+d[0-9]+h'
now_wk="$(printf '%(%s)T' -1)"
# <1 day, ≥1h → hours+minutes, "↻NhMm".
assert_match "week reset hours+minutes format (5.5h -> NhMm)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":'"$((now_wk+19800))"'}}}')" $'↻[0-9]+h[0-9]+m'
now_wk="$(printf '%(%s)T' -1)"
# <1h, ≥1m → minutes only, "↻Nm".
assert_match "week reset minutes format (30m -> Nm)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":'"$((now_wk+1800))"'}}}')" $'↻[0-9]+m( |$)'
now_wk="$(printf '%(%s)T' -1)"
# <1m → seconds, "↻Ns".
assert_match "week reset seconds format (45s -> Ns)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":'"$((now_wk+45))"'}}}')" $'↻[0-9]+s'
now_wk="$(printf '%(%s)T' -1)"
assert_not_contains "no week countdown when reset is in the past" \
  "$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":10,"resets_at":'"$((now_wk-100))"'}}}')" "↻"

echo "== bullet separator before timing/cost group =="
# A · sets off the timing/cost group from the ctx/quota group when both exist…
assert_contains "bullet before cost when quota present" \
  "$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":10}},"cost":{"total_cost_usd":3.50}}')" "· "
# …but NOT when there is no ctx/quota group to separate from.
assert_not_contains "no bullet when no middle fields precede cost" \
  "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":3.50}}')" "·"

echo "== elapsed-time formatting =="
assert_eq "duration seconds (5000ms -> 5s)"   "5s"    "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":5000}}'   | grep -oE '[0-9]+[hms].*$' | grep -oE '^[0-9]+s')"
assert_contains "duration minutes alone (65000ms -> 1m)" "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":65000}}')"   "1m"
assert_contains "duration h+m (7380000ms -> 2h3m)" "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":7380000}}')" "2h3m"
assert_contains "duration d+h (90000000ms -> 1d1h)" "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":90000000}}')" "1d1h"
assert_contains "duration exactly 1h (3600000ms -> 1h0m)" "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":3600000}}')" "1h0m"
assert_contains "duration 59s stays seconds (59000ms -> 59s)" "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":59000}}')" "59s"

echo "== cost formatting (%.2f) =="
assert_contains "cost \$11.55"        "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":11.55}}')" '$11.55'
assert_contains "cost pads to 2 dp"   "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":2}}')"     '$2.00'
assert_contains "cost small value"    "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":0.08}}')"  '$0.08'
assert_contains "cost colored yellow (93)" "$(render '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":11.55}}')" $'\033[93m$11.55'
# Rounding: cost goes through `_round2` — integer-cents, round-HALF-UP on the
# decimal text (NOT printf %.2f). This is deterministic and byte-identical to the
# native binary (printf %.2f and Rust {:.2} disagreed on half-cent values like
# 11.555/0.005; round2 does not). Pin the half-up values incl. carry.
assert_contains "rounding 2.675 -> \$2.68 (half-up)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":2.675}}')" '$2.68'
assert_contains "rounding 1.005 -> \$1.01 (half-up)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.005}}')" '$1.01'
assert_contains "rounding 0.125 -> \$0.13 (half-up)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":0.125}}')" '$0.13'
assert_contains "rounding 11.555 -> \$11.56 (half-up; was the bash↔Rust divergence)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":11.555}}')" '$11.56'
assert_contains "rounding 9.995 -> \$10.00 (carry)" \
  "$(render_plain '{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":9.995}}')" '$10.00'

echo "== missing / empty fields yield no broken segments =="
empty_out="$(render_plain '{}')"
assert_contains "empty envelope still renders model slot" "$empty_out" "[?]"
assert_not_contains "no stray 'ctx' with no context"  "$empty_out" "ctx"
assert_not_contains "no stray '5h' with no rate limit" "$empty_out" "5h"
assert_not_contains "no stray '\$' with no cost"       "$empty_out" '$'
assert_not_contains "no empty bullet/percent artifacts" "$empty_out" "%"

echo "== malformed numeric fields are guarded (no errors under set -u) =="
malformed='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":"NaN"},"cost":{"total_cost_usd":"abc","total_duration_ms":"--"},"rate_limits":{"five_hour":{"used_percentage":"yy","resets_at":"zz"},"seven_day":{"used_percentage":"qq"}}}'
mf_err="$(printf '%s' "$malformed" | CLAUDE_STATUSLINE_THROTTLE=0 bash "$SCRIPT" 2>&1 >/dev/null)"
mf_code=$?
assert_eq "malformed envelope exits 0"            "0"  "$mf_code"
assert_eq "malformed envelope writes nothing to stderr" "" "$mf_err"
mf_out="$(render_plain "$malformed")"
assert_contains "malformed still renders model"   "$mf_out" "[Opus]"
assert_not_contains "malformed cost suppressed"   "$mf_out" '$'
assert_not_contains "malformed ctx suppressed"    "$mf_out" "ctx"

echo "== Unit-Separator field join (absent fields don't shift columns) =="
# model + cost present, but effort/ctx/5h/wk ALL absent. If the jq->read join
# used a whitespace separator, the empty slots would collapse and the cost
# value would be read into the wrong variable. Assert cost lands correctly.
us_out="$(render_plain '{"model":{"display_name":"Opus"},"cwd":"/x/y/proj","cost":{"total_cost_usd":3.50}}')"
assert_eq "absent middle fields keep cost aligned" \
  "[Opus] [proj] \$3.50" "$us_out"
# Only seven_day present (five_hour absent): wk must show, 5h must NOT.
us2="$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":55}}}')"
assert_contains "lone seven_day shows wk" "$us2" "wk 55%"
assert_not_contains "lone seven_day shows no 5h" "$us2" "5h"
# Only five_hour present (seven_day absent): 5h must show, wk must NOT.
us3="$(render_plain '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":'"$((NOW+600))"'}}}')"
assert_contains "lone five_hour shows 5h" "$us3" "5h"
assert_not_contains "lone five_hour shows no wk" "$us3" "wk"

echo "== throttle fast-path (reprint cached line within window) =="
# Use an isolated TMPDIR so the cache file can't collide with anything real.
THROTTLE_TMP="$(mktemp -d)"
sid="test-throttle-sid"
env_a='{"session_id":"'"$sid"'","model":{"display_name":"Claude Opus 4.8"},"context_window":{"used_percentage":42}}'
env_b='{"session_id":"'"$sid"'","model":{"display_name":"Claude Haiku 4.5"},"context_window":{"used_percentage":99}}'
out_a="$(printf '%s' "$env_a" | TMPDIR="$THROTTLE_TMP" CLAUDE_STATUSLINE_THROTTLE=3600 bash "$SCRIPT")"
# Second call, DIFFERENT content, same session within window -> must reprint out_a.
out_b="$(printf '%s' "$env_b" | TMPDIR="$THROTTLE_TMP" CLAUDE_STATUSLINE_THROTTLE=3600 bash "$SCRIPT")"
assert_eq "second call within window reprints cached line" "$out_a" "$out_b"
assert_true "cache file is keyed on session_id" \
  test -r "$THROTTLE_TMP/claude-statusline-out-$sid"
# A DIFFERENT session_id must NOT reuse the first session's cache.
out_other="$(printf '%s' '{"session_id":"other-sid","model":{"display_name":"Claude Haiku 4.5"},"context_window":{"used_percentage":99}}' | TMPDIR="$THROTTLE_TMP" CLAUDE_STATUSLINE_THROTTLE=3600 bash "$SCRIPT")"
assert_ne "different session_id renders its own line (no cross-session reuse)" "$out_a" "$out_other"
# Throttle disabled (=0) always does a full render (ignores the cache).
out_fresh="$(printf '%s' "$env_b" | TMPDIR="$THROTTLE_TMP" CLAUDE_STATUSLINE_THROTTLE=0 bash "$SCRIPT")"
assert_ne "throttle=0 bypasses cache (full render)" "$out_a" "$out_fresh"
rm -rf "$THROTTLE_TMP"

echo "== template engine (CLAUDE_STATUSLINE_FIELDS) =="
tpl_env='{"model":{"display_name":"Claude Opus 4.8"},"effort":{"level":"high"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":1.5,"total_duration_ms":65000}}'
# Plain field + format.
assert_eq "tpl short model + usd" "Opus \$1.50" "$(render_tpl_plain '{json.model.display_name:short} {json.cost.total_cost_usd:usd}' "$tpl_env")"
# Named + bright color tokens emit the right SGR.
assert_eq "tpl color token" $'\033[31mhigh\033[0m' "$(render_tpl '{red}{json.effort.level}{reset}' "$tpl_env")"
assert_eq "tpl 256-color token" $'\033[38;5;208mx\033[0m' "$(render_tpl '{fg256:208}x{reset}' "$tpl_env")"
# Smart separator: shown only when flanked by content on both sides.
assert_eq "tpl sep shown when flanked" "a · b" "$(render_tpl_plain 'a {sep} b' '{}')"
assert_eq "tpl sep dropped when right empty" "a" "$(render_tpl_plain 'a {sep} {json.no.field}' '{}')"
assert_eq "tpl sep dropped when left empty" "b" "$(render_tpl_plain '{json.no.field} {sep} b' '{}')"
assert_eq "tpl sep:space dropped when left empty" "b" "$(render_tpl_plain '{json.no.field}{sep:space}b' '{}')"
# Auto-collapse: empty field doesn't leave a double space.
assert_eq "tpl auto-collapse empty field" "a b" "$(render_tpl_plain 'a {json.no.field} b' '{}')"
# Conditional group: hidden when field absent, shown when present.
assert_eq "tpl group hidden" "x y" "$(render_tpl_plain 'x{?json.no.field} z{/} y' '{}')"
assert_eq "tpl group shown" "x z y" "$(render_tpl_plain 'x{?json.context_window.used_percentage} z{/} y' "$tpl_env")"
# Arbitrary path access to a non-default field.
assert_eq "tpl raw field access" "+156/-23" "$(render_tpl_plain '+{json.cost.total_lines_added}/-{json.cost.total_lines_removed}' '{"cost":{"total_lines_added":156,"total_lines_removed":23}}')"
# :basename is pure (no workspace fallback); :folder carries value→cwd→$PWD.
assert_eq "tpl basename pure (empty in)" "" "$(render_tpl_plain '{json.no.path:basename}' '{}')"
assert_eq "tpl basename last component" "proj" "$(render_tpl_plain '{json.workspace.current_dir:basename}' '{"workspace":{"current_dir":"/a/b/proj"}}')"
assert_eq "tpl folder falls back to cwd" "zed" "$(render_tpl_plain '{json.workspace.current_dir:folder}' '{"cwd":"/x/y/zed"}')"
# Multi-line: literal \n becomes a second row.
assert_eq "tpl multi-line" $'Opus\nhigh' "$(render_tpl_plain '{json.model.display_name:short}\n{json.effort.level}' "$tpl_env")"
# Escapes: \e and \033 both yield ESC.
assert_eq "tpl \\e escape" $'\033[1mX\033[0m' "$(render_tpl '\e[1mX\e[0m' '{}')"
assert_eq "tpl \\033 escape" $'\033[1mX\033[0m' "$(render_tpl '\033[1mX\033[0m' '{}')"
# \xHH and \NNN name a Unicode codepoint emitted as UTF-8 (matches Rust); a lone
# surrogate from \uHHHH is dropped (char::from_u32 → None).
assert_eq "tpl \\xHH escape" $'\xc3\x83' "$(render_tpl '\xC3' '{}')"
assert_eq "tpl \\NNN octal escape" $'\xc3\x83' "$(render_tpl '\303' '{}')"
assert_eq "tpl \\uHHHH unicode escape" $'\xe2\x99\xa5' "$(render_tpl '♥' '{}')"
assert_eq "tpl lone surrogate dropped" "[]" "$(render_tpl_plain '[\uD83D]' '{}')"
# pct-plain (no color) and sep glyph variants.
assert_eq "tpl pct-plain" "42%" "$(render_tpl_plain '{json.context_window.used_percentage:pct-plain}' "$tpl_env")"
# pct (colored): green below 50, red at/above 80.
assert_eq "tpl pct colored green" $'\033[92m42%\033[0m' "$(render_tpl '{json.context_window.used_percentage:pct}' "$tpl_env")"
assert_eq "tpl pct colored red" $'\033[91m90%\033[0m' "$(render_tpl '{json.context_window.used_percentage:pct}' '{"context_window":{"used_percentage":90}}')"
assert_eq "tpl sep:dot" "a • b" "$(render_tpl_plain 'a {sep:dot} b' '{}')"
assert_eq "tpl sep:slash" "a / b" "$(render_tpl_plain 'a {sep:slash} b' '{}')"
assert_eq "tpl sep:space" "a b" "$(render_tpl_plain 'a{sep:space}b' '{}')"
# Background color variants.
assert_eq "tpl bg256" $'\033[48;5;200mo\033[0m' "$(render_tpl '{bg256:200}o{reset}' '{}')"
assert_eq "tpl bgrgb" $'\033[48;2;10;20;30mo\033[0m' "$(render_tpl '{bgrgb:10,20,30}o{reset}' '{}')"
assert_eq "tpl bg#hex" $'\033[48;2;255;0;128mo\033[0m' "$(render_tpl '{bg#ff0080}o{reset}' '{}')"
# A boolean false renders (jq // would drop it); group around it is present.
assert_eq "tpl boolean false" "ABfalseCD" "$(render_tpl_plain 'A{?json.x.y}B{json.x.y}C{/}D' '{"x":{"y":false}}')"
# {?path} without the json. prefix resolves against the root, like Rust.
assert_eq "tpl bare cond" "FOUND" "$(render_tpl_plain '{?foo}FOUND{/}' '{"foo":"bar"}')"
# A jq-injection attempt via a {json.PATH} token leaks nothing (path is data).
assert_eq "tpl no jq injection" "LEAK=" "$(HOME=secret render_tpl_plain 'LEAK={json.nope // $ENV.HOME) | (.}' '{}')"
# :countdown via the template engine (its own regex+delta branch, distinct from
# the hardcoded path): a future reset shows the ↻ glyph; reset==now is suppressed.
cd_now="$(printf '%(%s)T' -1)"
assert_contains "tpl countdown non-zero" "$(render_tpl '{json.r.resets_at:countdown}' '{"r":{"resets_at":'"$((cd_now+5400))"'}}')" $'↻'
assert_eq "tpl countdown at-now suppressed" "[]" "$(render_tpl_plain '[{json.r.resets_at:countdown}]' '{"r":{"resets_at":'"$cd_now"'}}')"
# Malformed templates must not error under set -u (exit 0, output is best-effort).
assert_true "tpl unterminated brace no error" bash -c 'printf "%s" "{}" | CLAUDE_STATUSLINE_THROTTLE=0 CLAUDE_STATUSLINE_FIELDS="{json.model" bash "'"$SCRIPT"'"'
assert_true "tpl unknown color no error" bash -c 'printf "%s" "{}" | CLAUDE_STATUSLINE_THROTTLE=0 CLAUDE_STATUSLINE_FIELDS="{octarine}x{reset}" bash "'"$SCRIPT"'"'
# The default template (with a trailing space to dodge the short-circuit) renders
# through the engine identically to the hardcoded path.
_dflt="$(sed -n "s/^DEFAULT_TEMPLATE='\(.*\)'\$/\1/p" "$SCRIPT")"
assert_eq "tpl default==hardcoded" "$(render "$tpl_env")" "$(render_tpl "$_dflt " "$tpl_env")"

echo "== throttle reprints multi-line templates intact =="
ml_tmp="$(mktemp -d)"; ml_sid="ml-sid"
ml_env='{"session_id":"'"$ml_sid"'","model":{"display_name":"Opus"},"effort":{"level":"high"}}'
ml_tpl='{json.model.display_name:short}\n{json.effort.level}'
ml_a="$(printf '%s' "$ml_env" | TMPDIR="$ml_tmp" CLAUDE_STATUSLINE_THROTTLE=3600 CLAUDE_STATUSLINE_FIELDS="$ml_tpl" bash "$SCRIPT")"
ml_b="$(printf '%s' '{"session_id":"'"$ml_sid"'","model":{"display_name":"Haiku"}}' | TMPDIR="$ml_tmp" CLAUDE_STATUSLINE_THROTTLE=3600 CLAUDE_STATUSLINE_FIELDS="$ml_tpl" bash "$SCRIPT")"
assert_eq "throttle reprint keeps both rows" $'Opus\nhigh' "$ml_b"
assert_eq "cached multi-line equals first render" "$ml_a" "$ml_b"
rm -rf "$ml_tmp"

echo "== bench.sh smoke test =="
if [ -r "$BENCH" ]; then
  bench_out="$(bash "$BENCH" 5 "$SCRIPT" 2>&1)"; bench_code=$?
  assert_eq "bench.sh exits 0 with small iter count" "0" "$bench_code"
  assert_contains "bench.sh prints Wall time" "$bench_out" "Wall time:"
  assert_contains "bench.sh reports the iteration count" "$bench_out" "iterations: 5"
else
  _bad "bench.sh present"; printf '         %s not found\n' "$BENCH"
fi

echo "== install.sh jq merge sanity (isolated; never touches ~/.claude) =="
if [ -r "$INSTALL" ]; then
  merge_tmp="$(mktemp -d)"
  settings="$merge_tmp/settings.json"
  # Pre-existing settings with unrelated keys, an old statusLine block, AND an
  # existing env var that must survive the env merge.
  printf '%s' '{"theme":"dark","permissions":{"allow":["x"]},"env":{"KEEP_ME":"yes"},"statusLine":{"type":"command","command":"OLD","refreshInterval":5}}' > "$settings"
  # Reproduce install.sh's exact merge (statusLine block + env-block merge).
  blk=$(jq -n --arg cmd "bash ~/.claude/statusline-command.sh" --argjson ri 60 \
    '{type:"command", command:$cmd, refreshInterval:$ri}')
  tmpf=$(mktemp)
  jq --argjson sl "$blk" --arg tpl "DEFTPL" --arg thr "2" --arg ctx "1000000" \
     '.statusLine = $sl
      | .env = ((.env // {}) + {CLAUDE_STATUSLINE_FIELDS:$tpl, CLAUDE_STATUSLINE_THROTTLE:$thr, CLAUDE_STATUSLINE_CTX_MAX:$ctx})' \
     "$settings" > "$tmpf" && mv "$tmpf" "$settings"
  assert_eq "merge preserves unrelated key (theme)" "dark" "$(jq -r '.theme' "$settings")"
  assert_eq "merge preserves nested key (permissions.allow[0])" "x" "$(jq -r '.permissions.allow[0]' "$settings")"
  assert_eq "merge updates statusLine.command" "bash ~/.claude/statusline-command.sh" "$(jq -r '.statusLine.command' "$settings")"
  assert_eq "merge sets refreshInterval" "60" "$(jq -r '.statusLine.refreshInterval' "$settings")"
  assert_eq "env merge preserves existing env var" "yes" "$(jq -r '.env.KEEP_ME' "$settings")"
  assert_eq "env merge writes the template" "DEFTPL" "$(jq -r '.env.CLAUDE_STATUSLINE_FIELDS' "$settings")"
  assert_eq "env merge writes throttle default" "2" "$(jq -r '.env.CLAUDE_STATUSLINE_THROTTLE' "$settings")"
  assert_true "merged settings is valid JSON" jq -e . "$settings"
  # Creating-from-scratch path (no existing settings.json).
  fresh="$merge_tmp/fresh.json"
  jq -n --argjson sl "$blk" --arg tpl "DEFTPL" --arg thr "2" --arg ctx "1000000" \
     '{statusLine: $sl, env: {CLAUDE_STATUSLINE_FIELDS:$tpl, CLAUDE_STATUSLINE_THROTTLE:$thr, CLAUDE_STATUSLINE_CTX_MAX:$ctx}}' > "$fresh"
  assert_eq "fresh settings keys are statusLine+env" "env statusLine" "$(jq -r 'keys|join(" ")' "$fresh")"
  rm -rf "$merge_tmp"
else
  _bad "install.sh present"; printf '         %s not found\n' "$INSTALL"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
