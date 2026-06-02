#!/usr/bin/env bash
# Claude Code statusline — single line, left-aligned.
#
# Renders, e.g.:
#   [Opus] high ctx █░░░░ 19% 5h ██░░░ 31% ↻3h49m wk 10% 1h16m $11.55
#
# All values come from the JSON envelope Claude Code pipes to stdin:
# - model.display_name → shortened to Opus/Sonnet/Haiku
# - effort.level → color-coded level shown next to the model
# - context_window.used_percentage → ctx bar (1M-aware via envelope)
# - rate_limits.five_hour → 5h bar + reset countdown
# - rate_limits.seven_day → wk (all-models weekly)
# - cost.{total_duration_ms, total_cost_usd} → elapsed + $ (last)
#
# Right-alignment was attempted via leading whitespace, the CHA cursor
# escape, and a ZWSP+spaces hack; Claude Code's TUI strips/miscounts
# all three. Reinstate once Claude Code adds an alignment hint.

set -u

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
#   - cache file: "<epoch>\n<rendered line>".
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
      # Fresh enough: reprint the cached line, skip all the work.
      { IFS= read -r _ts; IFS= read -r _cached; } < "$THROTTLE_CACHE"
      printf '%s' "$_cached"
      exit 0
    fi
  fi
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
  week_sonnet_pct \
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
        | map(select(.key | test("sonnet"; "i"))) | (.[0].value.used_percentage // ""))
  ] | map(tostring) | join("")' <<<"$input" 2>/dev/null)"

# ── Model short name ─────────────────────────────────────────────────
case "$model_full" in
  *Opus*)   model_short="Opus" ;;
  *Sonnet*) model_short="Sonnet" ;;
  *Haiku*)  model_short="Haiku" ;;
  *)        model_short="${model_full%% *}" ;;
esac
[ -z "$model_short" ] && model_short="?"

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
[[ "$cost_usd" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf -v cost_str '$%.2f' "$cost_usd"

duration_str=""
if [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
  secs=$(( duration_ms / 1000 ))
  if   [ "$secs" -ge 3600 ]; then printf -v duration_str '%dh%dm' "$((secs/3600))" "$(((secs%3600)/60))"
  elif [ "$secs" -ge 60 ];   then printf -v duration_str '%dm%ds' "$((secs/60))"   "$((secs%60))"
  else                            printf -v duration_str '%ds' "$secs"
  fi
fi

# ── Rate-limit quotas (from envelope, not local approximation) ───────
# Claude Code passes `rate_limits.five_hour.used_percentage` and
# `rate_limits.seven_day.used_percentage` (the latter = all-models week).
# `week_sonnet_pct` is the Sonnet-only week shown in /usage; it is NOT in
# the current envelope, so it stays empty (and its segment is omitted)
# until a Claude Code version surfaces it — see the jq extraction above.
[[ "$session_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] && session_pct=${session_pct%.*} || session_pct=""
[[ "$week_all_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] && week_all_pct=${week_all_pct%.*} || week_all_pct=""
[[ "$week_sonnet_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] && week_sonnet_pct=${week_sonnet_pct%.*} || week_sonnet_pct=""

# Time-until-reset for the 5h session window. `resets_at` is a unix
# timestamp; render the diff compactly: "2h15m", "45m", or "30s".
session_reset_in=""
if [[ "$session_resets_at" =~ ^[0-9]+$ ]]; then
  diff=$(( session_resets_at - now ))   # `now` computed once, above
  if   [ "$diff" -ge 3600 ]; then printf -v session_reset_in '%dh%dm' "$((diff/3600))" "$(((diff%3600)/60))"
  elif [ "$diff" -ge 60 ];   then printf -v session_reset_in '%dm' "$((diff/60))"
  elif [ "$diff" -gt 0 ];    then session_reset_in="${diff}s"
  fi
fi

# ── Colors ───────────────────────────────────────────────────────────
G=$'\033[92m'   # bright green
W=$'\033[97m'   # bright white
D=$'\033[90m'   # dim grey (separators)
Y=$'\033[93m'   # yellow (cost)
C=$'\033[96m'   # cyan (duration)
R=$'\033[0m'
SEP="${D}·${R}"  # bullet separator

# Color a percent number by severity: green<50, yellow<80, red>=80.
# Writes the SGR escape into the named variable (no $() subshell fork).
# Usage: pct_color <outvar> <n>
pct_color() {
  local -n _o="$1"; local n="$2"
  if   [ "$n" -ge 80 ]; then _o=$'\033[91m'        # bright red
  elif [ "$n" -ge 50 ]; then _o=$'\033[93m'        # yellow
  else                       _o=$'\033[92m'; fi    # green
}

# Render a progress bar: a solid filled portion (█) + a dotted empty
# portion (░), then the percentage. The fill color is a smooth gradient
# keyed to the value — green when low, easing through yellow/orange to
# red as it approaches full. Empty cells stay dim. Uses 256-color SGR.
# Writes the bar into the named variable (no $() subshell fork).
# Usage: render_bar <outvar> <pct> [width]
DG=$'\033[32m'    # dim green (empty-cell dots)
# 11-step green→red gradient (xterm-256 codes), indexed by pct/10.
BAR_GRAD=(46 82 118 154 190 226 220 214 208 202 196)
# Pre-rendered runs of block/dot glyphs (0..MAXW) so we don't loop per call.
_BARW=5
_FULL=(); _DOT=(); _f=""; _d=""
for ((_i=0; _i<=_BARW; _i++)); do _FULL[_i]="$_f"; _DOT[_i]="$_d"; _f+="█"; _d+="░"; done
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

# ── Build segments ───────────────────────────────────────────────────
# Effort sits right next to the model name; its color encodes the level.
effort_str=""
if [ -n "$effort_level" ]; then
  case "$effort_level" in
    high|max) effort_color=$'\033[91m' ;;   # red — most reasoning
    medium)   effort_color=$'\033[93m' ;;   # yellow
    *)        effort_color=$'\033[92m' ;;   # green — low/other
  esac
  effort_str=" ${effort_color}${effort_level}${R}"
fi
declare -a parts=()
parts+=("${G}[${model_short}]${R}${effort_str}")
[ -n "$project" ] && parts+=("${D}[${R}${W}${project}${R}${D}]${R}")
# Each of these is a distinct field, separated by the uniform separator
# below (the reset countdown stays glued to 5h as part of that field).
# Cost goes last.
if [ -n "$ctx_pct" ]; then render_bar _ctxbar "$ctx_pct"; parts+=("${W}ctx${R} $_ctxbar"); fi
if [ -n "$session_pct" ]; then
  render_bar _5hbar "$session_pct"
  five_seg="${W}5h${R} $_5hbar"
  [ -n "$session_reset_in" ] && five_seg="${five_seg} ${D}↻${R}${W}${session_reset_in}${R}"
  parts+=("$five_seg")
fi
# Weekly quotas: all-models (wk) and Sonnet-only (son, when available).
if [ -n "$week_all_pct" ];    then pct_color _wkc "$week_all_pct";  parts+=("${W}wk${R} ${_wkc}${week_all_pct}%${R}"); fi
if [ -n "$week_sonnet_pct" ]; then pct_color _snc "$week_sonnet_pct"; parts+=("${W}son${R} ${_snc}${week_sonnet_pct}%${R}"); fi
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
