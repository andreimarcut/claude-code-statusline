#!/usr/bin/env bash
# Claude Code statusline — single line (or multi-line), left-aligned.
#
# Default layout renders, e.g.:
#   [Opus] high [proj] ctx █░░░░ 19% 5h ██░░░ 31% ↻3h49m wk 10% · 1h16m $11.55
#
# All values come from the JSON envelope Claude Code pipes to stdin:
# - model.display_name → shortened to Opus/Sonnet/Haiku
# - effort.level → color-coded level shown next to the model
# - context_window.used_percentage → ctx bar (1M-aware via envelope)
# - rate_limits.five_hour → 5h bar + reset countdown
# - rate_limits.seven_day → wk (all-models weekly) + reset countdown
# - cost.{total_duration_ms, total_cost_usd} → elapsed + $ (last)
#
# The layout is configurable: set the CLAUDE_STATUSLINE_FIELDS env var (via the
# settings.json `env` block) to a template string and this script renders that
# instead. When it is unset/empty OR equals DEFAULT_TEMPLATE, the fast hardcoded
# path below runs. See TEMPLATES.md for the template syntax.
#
# Right-alignment was attempted via leading whitespace, the CHA cursor
# escape, and a ZWSP+spaces hack; Claude Code's TUI strips/miscounts
# all three. Reinstate once Claude Code adds an alignment hint.

set -u

# Pin the numeric locale for locale-INDEPENDENT numeric formatting, matching the
# native binary. Cost rounding goes through the integer-cents `_round2` (no
# `printf %f`), so this is now defense-in-depth — it guards any future
# locale-sensitive numeric format from drifting from the binary (a non-C locale
# would otherwise round differently or use a ',' decimal separator). Scoped to
# LC_NUMERIC (NOT LC_ALL) so LC_CTYPE stays the user's UTF-8 locale and
# `${var:i:1}` keeps walking by character (multibyte-safe) — the tokenizer needs it.
export LC_NUMERIC=C

# Read the whole JSON envelope from stdin with the `read` builtin (no
# fork). `-d ''` reads until NUL — i.e. the entire stdin — and returns
# non-zero at EOF, hence `|| true`. This replaces `$(cat)` (a fork) and,
# unlike `$(</dev/stdin)` (which reads empty under Claude Code's piping),
# reads the envelope correctly — verified against the live pipe.
IFS= read -rd '' input || true

# Current epoch (builtin, no `date` fork). Used by the throttle below and
# by the rate-limit reset countdown later.
printf -v now '%(%s)T' -1

# ── Throttle: bound how often the real work runs ─────────────────────
# Claude Code re-invokes this script on every event (each assistant
# message, etc.) plus the refreshInterval timer. To coalesce bursts, we
# cache the last rendered line per session and, if it's younger than
# CLAUDE_STATUSLINE_THROTTLE seconds, reprint it and exit BEFORE the jq
# parse — so most invocations cost just a builtin stdin read + a bash regex
# + a file read (no jq, zero forks). Set the env var to 0 to disable.
#   - session_id is pulled with a bash regex (no jq) to key the cache.
#   - cache file: "<epoch>\n<rendered line>" (line may itself span rows).
THROTTLE="${CLAUDE_STATUSLINE_THROTTLE:-2}"
[[ "$THROTTLE" =~ ^[0-9]+$ ]] || THROTTLE=0
THROTTLE_CACHE=""
if [ "$THROTTLE" -gt 0 ]; then
  # Constrain the captured id to a filesystem-safe class so a `/` or `..`
  # can't be smuggled into the cache path (defense-in-depth: session_id is
  # a Claude-Code-issued UUID, but never trust external input in a path).
  _sid="default"
  [[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]{1,64})\" ]] && _sid="${BASH_REMATCH[1]}"
  THROTTLE_CACHE="${TMPDIR:-/tmp}/claude-statusline-out-${_sid}"
  if [ -r "$THROTTLE_CACHE" ]; then
    IFS= read -r _ts < "$THROTTLE_CACHE" || _ts=""
    if [[ "$_ts" =~ ^[0-9]+$ ]] && [ "$(( now - _ts ))" -lt "$THROTTLE" ]; then
      # Fresh enough: reprint the cached line, skip all the work. `read -d ''`
      # captures the rest verbatim, including any embedded newlines (multi-row
      # templates), stopping at EOF.
      { IFS= read -r _ts; IFS= read -rd '' _cached; } < "$THROTTLE_CACHE"
      printf '%s' "$_cached"
      exit 0
    fi
  fi
fi

# ── Colors (must match native/src/lib.rs exactly for byte-identical output) ──
G=$'\033[92m'   # bright green
W=$'\033[97m'   # bright white
D=$'\033[90m'   # dim grey (separators)
Y=$'\033[93m'   # yellow (cost)
C=$'\033[96m'   # cyan (duration)
R=$'\033[0m'
SEP="${D}·${R}"  # bullet separator
DG=$'\033[32m'    # dim green (empty-cell dots)
# 11-step green→red gradient (xterm-256 codes), indexed by pct/10.
BAR_GRAD=(46 82 118 154 190 226 220 214 208 202 196)
# Pre-rendered runs of block/dot glyphs (0..MAXW) so we don't loop per call.
_BARW=5
_FULL=(); _DOT=(); _f=""; _d=""
for ((_i=0; _i<=_BARW; _i++)); do _FULL[_i]="$_f"; _DOT[_i]="$_d"; _f+="█"; _d+="░"; done

# Uniform duration formatting, used for every time field (uptime + both
# reset countdowns): the two largest units down to the hour ("4d3h",
# "5h12m"), then a single unit below ("30m", "45s"). Non-positive → empty
# (so a past reset shows no countdown); 0 seconds → "0s".
# Usage: fmt_dur <outvar> <seconds>
fmt_dur() {
  local -n _d="$1"; local s="$2"
  if   [ "$s" -ge 86400 ]; then printf -v _d '%dd%dh' "$((s/86400))" "$(((s%86400)/3600))"
  elif [ "$s" -ge 3600 ];  then printf -v _d '%dh%dm' "$((s/3600))"  "$(((s%3600)/60))"
  elif [ "$s" -ge 60 ];    then _d="$((s/60))m"
  elif [ "$s" -ge 0 ];     then _d="${s}s"
  else                          _d=""
  fi
}

# Color a percent number by severity: green<50, yellow<80, red>=80.
# Writes the SGR escape into the named variable (no $() subshell fork).
# Usage: pct_color <outvar> <n>
pct_color() {
  local -n _o="$1"; local n="$2"
  if   [ "$n" -ge 80 ]; then _o=$'\033[91m'        # bright red
  elif [ "$n" -ge 50 ]; then _o=$'\033[93m'        # yellow
  else                       _o=$'\033[92m'; fi    # green
}

# Format numeric text as dollars.cents, rounding half-up on the DECIMAL TEXT via
# integer math (no `printf %f`), so cost is byte-identical to the native binary's
# round2 regardless of locale or float-formatter quirks (bash `printf %.2f` and
# Rust `{:.2}` disagree on half-cent values; this does not).
# Usage: _round2 <outvar> <numeric-text>
_round2() {
  local -n _o2="$1"; local s="$2" sign="" int frac d2 cents
  [[ "$s" == -* ]] && { sign="-"; s="${s#-}"; }
  int="${s%%.*}"; frac=""; [[ "$s" == *.* ]] && frac="${s#*.}"
  frac="${frac}000"                       # ≥3 fractional digits for the round digit
  d2="${frac:0:2}"
  cents=$(( 10#$int * 100 + 10#$d2 ))
  [ "${frac:2:1}" -ge 5 ] && cents=$(( cents + 1 ))
  printf -v _o2 '%s%d.%02d' "$sign" "$((cents/100))" "$((cents%100))"
}

# Render a progress bar: a solid filled portion (█) + a dotted empty
# portion (░), then the percentage. The fill color is a smooth gradient
# keyed to the value — green when low, easing through yellow/orange to
# red as it approaches full. Empty cells stay dim. Uses 256-color SGR.
# Writes the bar into the named variable (no $() subshell fork).
# Usage: render_bar <outvar> <pct> [width]
render_bar() {
  local -n _out="$1"; local pct="$2" width="${3:-$_BARW}"
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ]   && pct=0
  local filled=$(( (pct * width + 50) / 100 ))   # rounded
  [ "$filled" -gt "$width" ] && filled="$width"
  local gi=$(( pct / 10 )); [ "$gi" -gt 10 ] && gi=10
  local fc; printf -v fc '\033[38;5;%dm' "${BAR_GRAD[gi]}"
  _out="${fc}${_FULL[filled]}${DG}${_DOT[$(( width - filled ))]}${R} ${W}${pct}%${R}"
}

# ── Template engine (opt-in via CLAUDE_STATUSLINE_FIELDS) ─────────────
# Mirror of native/src/lib.rs's engine — MUST produce byte-identical output.
# The default install writes DEFAULT_TEMPLATE into the settings.json `env`
# block; since the dispatch below short-circuits when the template equals it,
# the engine only runs for genuinely customized templates. See TEMPLATES.md.
DEFAULT_TEMPLATE='{bright_green}[{json.model.display_name:short}]{reset}{json.effort.level:effort} {grey}[{reset}{bright_white}{json.workspace.current_dir:folder}{reset}{grey}]{reset}{^}{?json.context_window.used_percentage} {bright_white}ctx{reset} {json.context_window.used_percentage:bar}{/}{?json.rate_limits.five_hour.used_percentage} {bright_white}5h{reset} {json.rate_limits.five_hour.used_percentage:bar}{json.rate_limits.five_hour.resets_at:countdown}{/}{?json.rate_limits.seven_day.used_percentage} {bright_white}wk{reset} {json.rate_limits.seven_day.used_percentage:pct}{json.rate_limits.seven_day.resets_at:countdown}{/}{?json.rate_limits.__sonnet__.used_percentage} {bright_white}son{reset} {json.rate_limits.__sonnet__.used_percentage:pct}{/} {sep} {json.cost.total_duration_ms:dur} {json.cost.total_cost_usd:usd}'

# Foreground SGR code for a named/bright color (for the bg_ offset). Empty if unknown.
_fg_code() {
  local -n __c="$1"
  case "$2" in
    black)__c=30;; red)__c=31;; green)__c=32;; yellow)__c=33;; blue)__c=34;;
    magenta)__c=35;; cyan)__c=36;; white)__c=37;;
    bright_black|grey|gray)__c=90;; bright_red)__c=91;; bright_green)__c=92;;
    bright_yellow)__c=93;; bright_blue)__c=94;; bright_magenta)__c=95;;
    bright_cyan)__c=96;; bright_white)__c=97;; *)__c="";;
  esac
}

# Named/extended color token → SGR escape in <outvar>; returns 1 if unrecognized.
color_token() {
  local -n __t="$1"; local n="$2"; __t=""
  case "$n" in
    reset)__t=$'\033[0m';; bold)__t=$'\033[1m';; dim)__t=$'\033[2m';;
    italic)__t=$'\033[3m';; underline)__t=$'\033[4m';; blink)__t=$'\033[5m';;
    reverse)__t=$'\033[7m';; hidden)__t=$'\033[8m';; strike)__t=$'\033[9m';;
    bg_*) local _bc; _fg_code _bc "${n#bg_}"; [ -n "$_bc" ] && printf -v __t '\033[%dm' "$((_bc+10))";;
    fg256:*) local v="${n#fg256:}"; [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -le 255 ] && printf -v __t '\033[38;5;%dm' "$v";;
    bg256:*) local v="${n#bg256:}"; [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -le 255 ] && printf -v __t '\033[48;5;%dm' "$v";;
    rgb:*) local s="${n#rgb:}"; [[ "$s" =~ ^([0-9]+),([0-9]+),([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] && [ "${BASH_REMATCH[3]}" -le 255 ] && printf -v __t '\033[38;2;%d;%d;%dm' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}";;
    bgrgb:*) local s="${n#bgrgb:}"; [[ "$s" =~ ^([0-9]+),([0-9]+),([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] && [ "${BASH_REMATCH[3]}" -le 255 ] && printf -v __t '\033[48;2;%d;%d;%dm' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}";;
    'bg#'*) local h="${n#bg#}"; [[ "$h" =~ ^[0-9A-Fa-f]{6}$ ]] && printf -v __t '\033[48;2;%d;%d;%dm' "$((16#${h:0:2}))" "$((16#${h:2:2}))" "$((16#${h:4:2}))";;
    '#'*) local h="${n#\#}"; [[ "$h" =~ ^[0-9A-Fa-f]{6}$ ]] && printf -v __t '\033[38;2;%d;%d;%dm' "$((16#${h:0:2}))" "$((16#${h:2:2}))" "$((16#${h:4:2}))";;
    *) local _fc; _fg_code _fc "$n"; [ -n "$_fc" ] && printf -v __t '\033[%dm' "$_fc";;
  esac
  [ -n "$__t" ]
}

# Shorten a model display name to Opus/Sonnet/Haiku, else its first word, else "?".
_model_short() {
  local -n __m="$1"
  case "$2" in
    *Opus*) __m="Opus";; *Sonnet*) __m="Sonnet";; *Haiku*) __m="Haiku";;
    *) __m="${2%% *}";;
  esac
  [ -z "$__m" ] && __m="?"
}

# Effort level → SGR color (high/max red, medium yellow, else green).
_effort_color() {
  local -n __e="$1"
  case "$2" in high|max) __e=$'\033[91m';; medium) __e=$'\033[93m';; *) __e=$'\033[92m';; esac
}

# Separator glyph for {sep[:type]} (dim-grey, except `space`).
_sep_glyph() {
  local -n __s="$1"
  case "$2" in
    space) __s=" ";; pipe) __s="${D}|${R}";; dot) __s="${D}•${R}";; slash) __s="${D}/${R}";;
    *) __s="${D}·${R}";;
  esac
}

# Render one {json.path:fmt} value. _FV (assoc) holds raw extracted values.
# Usage: _fmt_field <outvar> <path> <fmt>
_fmt_field() {
  local -n __o="$1"; local p="$2" f="$3"; __o=""
  # An empty path (e.g. `{json.}`) is not a valid assoc-array subscript under
  # set -u; treat it as absent (empty), matching Rust's empty resolve.
  if [ -z "$p" ]; then
    if [ "$f" = folder ]; then local _dd="${_FV[cwd]:-}"; [ -z "$_dd" ] && _dd="$PWD"; __o="${_dd##*/}"; fi
    return
  fi
  local v="${_FV[$p]:-}"
  case "$f" in
    short) _model_short __o "$v";;
    basename) __o="${v##*/}";;
    folder) local _dd="$v"; [ -z "$_dd" ] && _dd="${_FV[cwd]:-}"; [ -z "$_dd" ] && _dd="$PWD"; __o="${_dd##*/}";;
    effort)
      if [ -n "$v" ]; then local _ec; _effort_color _ec "$v"; __o=" ${_ec}${v}${R}"; fi;;
    bar) [[ "$v" =~ ^-?[0-9]{1,15}(\.[0-9]+)?$ ]] && render_bar __o "${v%.*}";;
    pct) if [[ "$v" =~ ^-?[0-9]{1,15}(\.[0-9]+)?$ ]]; then local _pc; pct_color _pc "${v%.*}"; __o="${_pc}${v%.*}%${R}"; fi;;
    pct-plain) [[ "$v" =~ ^-?[0-9]{1,15}(\.[0-9]+)?$ ]] && __o="${v%.*}%";;
    dur) if [[ "$v" =~ ^-?[0-9]{1,15}(\.[0-9]+)?$ ]]; then local _du; fmt_dur _du "$((${v%.*}/1000))"; [ -n "$_du" ] && __o="${C}${_du}${R}"; fi;;
    usd) if [[ "$v" =~ ^-?[0-9]{1,15}(\.[0-9]+)?$ ]]; then local _rc; _round2 _rc "$v"; __o="${Y}\$${_rc}${R}"; fi;;
    countdown) if [[ "$v" =~ ^-?[0-9]{1,15}(\.[0-9]+)?$ ]] && [ "$((${v%.*}-now))" -gt 0 ]; then local _cd; fmt_dur _cd "$((${v%.*}-now))"; [ -n "$_cd" ] && __o=" ${D}↻${R}${W}${_cd}${R}"; fi;;
    *) __o="$v";;
  esac
}

# Map a referenced dotted path (the Nth positional arg) to a jq extraction
# expression (into <outvar>, no subshell — matches the file's fork-free helper
# discipline). The path text is passed to jq as DATA ($ARGS.positional[N]),
# never interpolated into the program, so a {json.PATH} token can't inject jq.
# Resolution mirrors Rust: literal dotted-segment lookup via getpath, with the
# synthetic `rate_limits.__sonnet__` segment selecting any sonnet-ish bucket.
# null → "" (only null collapses, so a boolean `false` survives as "false").
_ref_to_jq() {
  local -n __j="$1"; local n="$2"
  # `try … catch null`: a path that indexes THROUGH a scalar (e.g.
  # {json.model.display_name.x}) makes getpath throw; without the catch, jq would
  # abort the whole program and every field would come back empty. Catching to
  # null → "" for just that field mirrors Rust's J::path returning None.
  printf -v __j '(($ARGS.positional[%d] | split(".")) as $pp | (try (if ($pp[0]=="rate_limits" and $pp[1]=="__sonnet__") then ((.rate_limits // {}) | to_entries | map(select(.key|test("sonnet";"i"))) | (.[0].value // null) | getpath($pp[2:])) else getpath($pp) end) catch null) | if . == null then "" else . end)' "$n"
}

# Engine item arrays (parallel): _ITX text, _ICL class char.
# Classes: V=visible G=gap Z=zero-width N=newline E=empty S=sep B=boundary.
_eng_push() { _ITX+=("$1"); _ICL+=("$2"); }

# Split the accumulated literal (_LIT) into V / G / N items.
_eng_flush_lit() {
  local s="$_LIT" cur="" ws=0 ch j=0 m=${#_LIT}
  while [ "$j" -lt "$m" ]; do
    ch="${s:j:1}"; j=$((j+1))
    if [ "$ch" = $'\n' ]; then
      if [ -n "$cur" ]; then [ "$ws" = 1 ] && _eng_push "" G || _eng_push "$cur" V; cur=""; fi
      _eng_push "" N; ws=0
    elif [ "$ch" = " " ] || [ "$ch" = $'\t' ]; then
      if [ "$ws" = 0 ] && [ -n "$cur" ]; then _eng_push "$cur" V; cur=""; fi
      ws=1; cur+="$ch"
    else
      if [ "$ws" = 1 ] && [ -n "$cur" ]; then _eng_push "" G; cur=""; fi
      ws=0; cur+="$ch"
    fi
  done
  [ -n "$cur" ] && { [ "$ws" = 1 ] && _eng_push "" G || _eng_push "$cur" V; }
  _LIT=""
}

# Interpret a backslash escape at _T[_I]; append to _LIT and advance _I.
_eng_unescape() {
  local nc="${_T:_I+1:1}" h c val j d
  case "$nc" in
    e) _LIT+=$'\033'; _I=$((_I+2));;
    n) _LIT+=$'\n'; _I=$((_I+2));;
    t) _LIT+=$'\t'; _I=$((_I+2));;
    '\') _LIT+='\'; _I=$((_I+2));;
    '{') _LIT+='{'; _I=$((_I+2));;
    '}') _LIT+='}'; _I=$((_I+2));;
    # \xHH and \uHHHH name a Unicode CODEPOINT (not a raw byte), emitted as
    # UTF-8 — matching Rust's char::from_u32(..).push (lib.rs unescape_into).
    # A lone surrogate (U+D800..U+DFFF) is dropped in both engines.
    x) h="${_T:_I+2:2}"; if [[ "$h" =~ ^[0-9A-Fa-f]{2}$ ]]; then printf -v c '\u00'"$h"; _LIT+="$c"; _I=$((_I+4)); else _LIT+='\'; _I=$((_I+1)); fi;;
    u) h="${_T:_I+2:4}"; if [[ "$h" =~ ^[0-9A-Fa-f]{4}$ ]]; then if [[ "$h" =~ ^[Dd][89A-Fa-f] ]]; then :; else printf -v c '\u'"$h"; _LIT+="$c"; fi; _I=$((_I+6)); else _LIT+='\'; _I=$((_I+1)); fi;;
    [0-7])
      j=$((_I+1)); val=0; local cnt=0
      while [ "$j" -lt "${#_T}" ] && [ "$cnt" -lt 3 ]; do d="${_T:j:1}"; case "$d" in [0-7]) val=$((val*8+d)); j=$((j+1)); cnt=$((cnt+1));; *) break;; esac; done
      printf -v c '%08x' "$val"; printf -v c '\U'"$c"; _LIT+="$c"; _I=$j;;
    *) _LIT+='\'; _I=$((_I+1));;
  esac
}

# Classify a {placeholder} (without braces) into an item.
_eng_classify() {
  local inner="$1"
  if [ "$inner" = "^" ]; then _eng_push "" B; return; fi
  if [ "$inner" = "sep" ] || [[ "$inner" == sep:* ]]; then
    local kind="bullet"; [[ "$inner" == sep:* ]] && kind="${inner#sep:}"
    local g; _sep_glyph g "$kind"; _eng_push "$g" S; return
  fi
  if [[ "$inner" == json.* ]]; then
    local body="${inner#json.}" path fmt out
    if [[ "$body" == *:* ]]; then path="${body%%:*}"; fmt="${body#*:}"; else path="$body"; fmt="text"; fi
    _fmt_field out "$path" "$fmt"
    [ -n "$out" ] && _eng_push "$out" V || _eng_push "" E
    return
  fi
  local ct; if color_token ct "$inner"; then _eng_push "$ct" Z; return; fi
  _eng_push "{$inner}" V
}

# A smart {sep} survives only when flanked by visible content on both sides
# (scanning past G/Z/E; another S, an N, or a B boundary blocks). dir: L|R.
_eng_has_vis() {
  local dir="$1" idx="$2" j
  if [ "$dir" = R ]; then
    for ((j=idx+1; j<${#_ICL[@]}; j++)); do case "${_ICL[j]}" in V) return 0;; S|N|B) return 1;; esac; done
  else
    for ((j=idx-1; j>=0; j--)); do case "${_ICL[j]}" in V) return 0;; S|N|B) return 1;; esac; done
  fi
  return 1
}

# Render a template string into `line`. Pure w.r.t. `now`/`input` (read globally).
_render_template() {
  _T="$1"; local nn=${#_T} ch rest inner
  # Pass 1: collect referenced json paths (+ cwd, always, for the :folder fallback chain).
  declare -A _seen=([cwd]=1); local -a REFS=(cwd) ppath
  _I=0
  while [ "$_I" -lt "$nn" ]; do
    ch="${_T:_I:1}"
    if [ "$ch" = '\' ]; then _I=$((_I+2)); continue; fi
    if [ "$ch" = '{' ]; then
      rest="${_T:_I+1}"; inner="${rest%%\}*}"
      if [ "$inner" != "$rest" ]; then
        _I=$(( _I + 2 + ${#inner} ))
        ppath=""
        case "$inner" in
          # {?path} resolves against the JSON root with the `json.` prefix
          # optional (mirrors Rust's cond.strip_prefix("json.").unwrap_or).
          '?'*) ppath="${inner#\?}"; ppath="${ppath#json.}";;
          'json.'*) ppath="${inner#json.}"; ppath="${ppath%%:*}";;
        esac
        if [ -n "$ppath" ] && [ -z "${_seen[$ppath]:-}" ]; then REFS+=("$ppath"); _seen[$ppath]=1; fi
        continue
      fi
    fi
    _I=$((_I+1))
  done
  # One jq fork extracts every referenced path. Paths are passed as DATA
  # (--args …), never interpolated into the program, so a crafted {json.PATH}
  # token cannot inject jq (e.g. read $ENV). Each value is TERMINATED (not just
  # joined) by 0x1f so the slot count is exact, and we split on 0x1f ONLY —
  # newlines inside a value are preserved, matching the Rust engine.
  local prog="[" first=1 _je; local ix=0
  for p in "${REFS[@]}"; do [ "$first" = 1 ] || prog+=","; _ref_to_jq _je "$ix"; prog+="$_je"; first=0; ix=$((ix+1)); done
  # Canonicalize each value to mirror Rust's node_text EXACTLY (lib.rs):
  #   array/object → "" (non-scalars are empty in both engines);
  #   whole-valued number with |x|<9e15 → integer form (so `42.0`/`5e1` → `42`/`50`,
  #     matching `format!("{}", x as i64)`); other numbers → jq's literal.
  # Keeps `{json.path}` text and `{?json.path}` presence byte-identical to Rust.
  prog+='] | map(((if (type=="array" or type=="object") then "" elif (type=="number" and . == floor and (if .<0 then -. else . end) < 9e15) then (floor|tostring) else tostring end) | gsub("\u001f";"")) + "\u001f") | join("")'
  local -a _VALS=(); IFS=$'\x1f' read -r -d '' -a _VALS \
    < <(jq -j "$prog" --args "${REFS[@]}" <<<"$input" 2>/dev/null)
  declare -A _FV=(); local k=0
  for p in "${REFS[@]}"; do _FV[$p]="${_VALS[k]:-}"; k=$((k+1)); done

  # Pass 2: tokenize into items, honoring conditional groups {?path}…{/}.
  _ITX=(); _ICL=(); _LIT=""; local -a _FR=()
  _eng_active() { local f; for f in ${_FR[@]+"${_FR[@]}"}; do [ "$f" = 0 ] && return 1; done; return 0; }
  _I=0
  while [ "$_I" -lt "$nn" ]; do
    ch="${_T:_I:1}"
    if [ "$ch" = '\' ] && [ "$((_I+1))" -lt "$nn" ]; then
      if _eng_active; then _eng_unescape; else _I=$((_I+2)); fi
      continue
    fi
    if [ "$ch" = '{' ]; then
      rest="${_T:_I+1}"; inner="${rest%%\}*}"
      if [ "$inner" != "$rest" ]; then
        _I=$(( _I + 2 + ${#inner} ))
        if [ "$inner" = "/" ]; then
          if _eng_active; then _eng_flush_lit; else _LIT=""; fi
          [ "${#_FR[@]}" -gt 0 ] && _FR=("${_FR[@]:0:${#_FR[@]}-1}")
          continue
        fi
        if [[ "$inner" == '?'* ]]; then
          if _eng_active; then _eng_flush_lit; else _LIT=""; fi
          local cond="${inner#\?}"; cond="${cond#json.}"
          # An empty cond (`{?}`) is not a valid assoc subscript under set -u;
          # treat it as absent, matching Rust (group dropped).
          if [ -n "$cond" ] && [ -n "${_FV[$cond]:-}" ]; then _FR+=(1); else _FR+=(0); fi
          continue
        fi
        if _eng_active; then _eng_flush_lit; _eng_classify "$inner"; else _LIT=""; fi
        continue
      fi
    fi
    if _eng_active; then _LIT+="$ch"; fi
    _I=$((_I+1))
  done
  _eng_flush_lit

  # Resolve smart separators.
  local m=${#_ICL[@]} idx
  for ((idx=0; idx<m; idx++)); do
    [ "${_ICL[idx]}" = "S" ] || continue
    if _eng_has_vis L "$idx" && _eng_has_vis R "$idx"; then :; else _ITX[idx]=""; _ICL[idx]="E"; fi
  done

  # Emit, collapsing gaps next to empties (single space; trim line ends).
  local out="" pending=0 vis=0
  for ((idx=0; idx<m; idx++)); do
    case "${_ICL[idx]}" in
      N) out+=$'\n'; pending=0; vis=0;;
      G) [ "$vis" = 1 ] && pending=1;;
      E|B) :;;
      Z) [ "$pending" = 1 ] && { out+=" "; pending=0; }; out+="${_ITX[idx]}";;
      V|S) [ "$pending" = 1 ] && { out+=" "; pending=0; }; out+="${_ITX[idx]}"; vis=1;;
    esac
  done
  line="$out"
}

# ── Layout dispatch ──────────────────────────────────────────────────
# Custom template → engine; unset/empty or the default → fast hardcoded path.
TEMPLATE="${CLAUDE_STATUSLINE_FIELDS:-}"
if [ -n "$TEMPLATE" ] && [ "$TEMPLATE" != "$DEFAULT_TEMPLATE" ]; then
  _render_template "$TEMPLATE"
  [ -n "$THROTTLE_CACHE" ] && printf '%s\n%s' "$now" "$line" > "$THROTTLE_CACHE" 2>/dev/null
  printf '%s' "$line"
  exit 0
fi

# ── Parse the whole envelope in ONE jq fork ──────────────────────────
# Forking jq once per field (12×) dominated this script's runtime
# (~48ms of ~73ms). Extract every field we need in a single jq call.
# Fields are joined with ASCII Unit Separator (0x1f), NOT tab: tab is an
# "IFS whitespace" char, so `read` would collapse consecutive tabs and
# silently drop absent fields, shifting every later column. 0x1f is
# non-whitespace, so empty fields keep their position. `// ""` (not
# `// empty`) keeps the slot present; the trailing \n in IFS just trims
# the here-string's newline off the last field.
IFS=$'\x1f\n' read -r \
  model_full effort_level dir_cur dir_cwd session_id ctx_pct \
  transcript cost_usd duration_ms session_pct week_all_pct session_resets_at \
  week_sonnet_pct week_resets_at \
  <<<"$(jq -r '[
    .model.display_name // "",
    .effort.level // "",
    .workspace.current_dir // "",
    .cwd // "",
    .session_id // "",
    (.context_window.used_percentage // ""),
    .transcript_path // "",
    (.cost.total_cost_usd // ""),
    (.cost.total_duration_ms // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    # Sonnet-only weekly bucket. /usage shows it, but current Claude Code
    # does NOT put it in the status-line envelope. Scan rate_limits for
    # ANY key mentioning "sonnet" so this lights up automatically if a
    # future version adds it (under whatever name). Empty until then.
    ((.rate_limits // {}) | to_entries
        | map(select(.key | test("sonnet"; "i"))) | (.[0].value.used_percentage // "")),
    (.rate_limits.seven_day.resets_at // "")
  ] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null)"

# ── Model short name ─────────────────────────────────────────────────
_model_short model_short "$model_full"

# effort_level is already parsed above (effort.level: low / medium / high).

# Current folder name (basename, fork-free) — shown next to the model.
dir="$dir_cur"
[ -z "$dir" ] && dir="$dir_cwd"
[ -z "$dir" ] && dir="$PWD"
project=${dir##*/}

# ── Context % ────────────────────────────────────────────────────────
# Prefer Claude Code's own number — it knows the active context window
# size per model (Opus 4.7 and Sonnet 4.6 are 1M, older models 200k) and
# already strips off cache_read tokens that shouldn't count against the
# live window. The transcript-summing fallback below is only used if the
# envelope doesn't carry it (older Claude Code versions).
if [[ "$ctx_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  ctx_pct=${ctx_pct%.*}     # strip decimals
else
  ctx_pct=""
  ctx_used=""
  if [ -n "$transcript" ] && [ -r "$transcript" ]; then
    ctx_used=$(tail -n 200 "$transcript" 2>/dev/null \
      | jq -rs '[.[] | select(.type=="assistant" and .message.usage)] | last | .message.usage | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))' 2>/dev/null \
      || true)
  fi
  # Default to 1M (current Opus/Sonnet); allow override via env if you
  # routinely use a 200k-only model.
  CTX_MAX="${CLAUDE_STATUSLINE_CTX_MAX:-1000000}"
  if [[ "$ctx_used" =~ ^[0-9]+$ ]] && [ "$ctx_used" -gt 0 ]; then
    ctx_pct=$(( ctx_used * 100 / CTX_MAX ))
    [ "$ctx_pct" -gt 100 ] && ctx_pct=100
  fi
fi

# ── Cost + duration ──────────────────────────────────────────────────
# bash's printf handles floats, so no `awk` fork. Guard on a numeric
# value so a malformed cost yields an empty segment, not a printf error.
cost_str=""
[[ "$cost_usd" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && { _round2 _cs "$cost_usd"; cost_str="\$${_cs}"; }

duration_str=""
[[ "$duration_ms" =~ ^[0-9]+$ ]] && fmt_dur duration_str "$(( duration_ms / 1000 ))"

# ── Rate-limit quotas (from envelope, not local approximation) ───────
# Claude Code passes `rate_limits.five_hour.used_percentage` and
# `rate_limits.seven_day.used_percentage` (the latter = all-models week).
# `week_sonnet_pct` is the Sonnet-only week shown in /usage; it is NOT in
# the current envelope, so it stays empty (and its segment is omitted)
# until a Claude Code version surfaces it — see the jq extraction above.
[[ "$session_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] && session_pct=${session_pct%.*} || session_pct=""
[[ "$week_all_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] && week_all_pct=${week_all_pct%.*} || week_all_pct=""
[[ "$week_sonnet_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] && week_sonnet_pct=${week_sonnet_pct%.*} || week_sonnet_pct=""

# Time-until-reset for the 5h session and 7-day windows. `resets_at` is a
# unix timestamp; fmt_dur renders the diff uniformly ("4d3h"/"5h12m"/"30m"/
# "45s") and yields empty for a past reset (so no countdown shows).
session_reset_in=""
[[ "$session_resets_at" =~ ^[0-9]+$ ]] && fmt_dur session_reset_in "$(( session_resets_at - now ))"
[ "$session_reset_in" = "0s" ] && session_reset_in=""

week_reset_in=""
[[ "$week_resets_at" =~ ^[0-9]+$ ]] && fmt_dur week_reset_in "$(( week_resets_at - now ))"
[ "$week_reset_in" = "0s" ] && week_reset_in=""

# ── Build segments ───────────────────────────────────────────────────
# Effort sits right next to the model name; its color encodes the level.
effort_str=""
if [ -n "$effort_level" ]; then
  _effort_color effort_color "$effort_level"
  effort_str=" ${effort_color}${effort_level}${R}"
fi
declare -a parts=()
parts+=("${G}[${model_short}]${R}${effort_str}")
[ -n "$project" ] && parts+=("${D}[${R}${W}${project}${R}${D}]${R}")
# Each of these is a distinct field, separated by the uniform separator
# below (the reset countdown stays glued to 5h as part of that field).
# Cost goes last.
_group_base=${#parts[@]}   # mark: any ctx/quota segment lands past here
if [ -n "$ctx_pct" ]; then render_bar _ctxbar "$ctx_pct"; parts+=("${W}ctx${R} $_ctxbar"); fi
if [ -n "$session_pct" ]; then
  render_bar _5hbar "$session_pct"
  five_seg="${W}5h${R} $_5hbar"
  [ -n "$session_reset_in" ] && five_seg="${five_seg} ${D}↻${R}${W}${session_reset_in}${R}"
  parts+=("$five_seg")
fi
# Weekly quotas: all-models (wk) and Sonnet-only (son, when available).
if [ -n "$week_all_pct" ]; then
  pct_color _wkc "$week_all_pct"
  wk_seg="${W}wk${R} ${_wkc}${week_all_pct}%${R}"
  [ -n "$week_reset_in" ] && wk_seg="${wk_seg} ${D}↻${R}${W}${week_reset_in}${R}"
  parts+=("$wk_seg")
fi
if [ -n "$week_sonnet_pct" ]; then pct_color _snc "$week_sonnet_pct"; parts+=("${W}son${R} ${_snc}${week_sonnet_pct}%${R}"); fi
# Set off the timing/cost group from the ctx/quota group with a bullet
# separator — but only when there's a ctx/quota group to separate from.
{ [ "${#parts[@]}" -gt "$_group_base" ] && { [ -n "$duration_str" ] || [ -n "$cost_str" ]; }; } && parts+=("$SEP")
[ -n "$duration_str" ] && parts+=("${C}${duration_str}${R}")
[ -n "$cost_str" ] && parts+=("${Y}${cost_str}${R}")   # cost last

line=""
for i in "${!parts[@]}"; do
  [ "$i" -gt 0 ] && line+=" "
  line+="${parts[$i]}"
done

# Save for the throttle fast-path (cheap reprint on the next burst call).
[ -n "$THROTTLE_CACHE" ] && printf '%s\n%s' "$now" "$line" > "$THROTTLE_CACHE" 2>/dev/null

printf '%s' "$line"
