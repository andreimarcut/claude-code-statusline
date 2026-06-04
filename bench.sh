#!/usr/bin/env bash
# Benchmark the Claude Code status line: wall time, CPU, CPU%, peak RAM, forks.
# Works for BOTH the bash script and the native binary.
#
# Usage:
#   ./bench.sh                       # THIS repo's script, ENGINE path (a real
#                                    #   custom template) — the feature's true cost
#   ./bench.sh 500                   # custom iteration count
#   ./bench.sh --native              # THIS repo's native binary, engine path
#   ./bench.sh --no-template         # the DEFAULT hardcoded path (no env var set)
#   ./bench.sh --template='{json.model.display_name:short} {json.cost.total_cost_usd:usd}'
#   ./bench.sh 500 /path/to/target   # explicit script (.sh) OR binary overrides the default
#
# DEFAULTS: bench this repo (pass a path to bench another, e.g. the installed
# ~/.claude copy) and bench WITH a custom template (the engine path: full
# tokenize + dynamic jq + format dispatch). Use --no-template to measure the
# default hardcoded path instead (engine short-circuited, no CLAUDE_STATUSLINE_FIELDS).
#
# Requires bash 5+ (EPOCHREALTIME) and jq. Peak-RAM and fork-count are
# Linux-only (/proc); they degrade gracefully elsewhere.
set -u
export LC_ALL=C   # '.' decimal separator in EPOCHREALTIME

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE=0; ENGINE=1; TEMPLATE_ARG=""; pos=()   # ENGINE on by default
for a in "$@"; do case "$a" in
  --native) NATIVE=1 ;;
  --no-template|--default|--hardcoded) ENGINE=0 ;;
  --engine) ENGINE=1 ;;
  --template=*) TEMPLATE_ARG="${a#--template=}"; ENGINE=1 ;;
  *) pos+=("$a") ;;
esac; done
ITERS="${pos[0]:-200}"; TARGET="${pos[1]:-}"

command -v jq >/dev/null || { echo "error: jq required" >&2; exit 1; }

# ── Resolve target ───────────────────────────────────────────────────
# Default to THIS repo (so the bench reflects the code under review). Pass an
# explicit path as the 2nd positional arg to bench another copy (e.g. the
# installed ~/.claude/statusline-command.sh).
if [ -z "$TARGET" ]; then
  if [ "$NATIVE" = 1 ]; then
    TARGET="$HERE/native/target/release/claude-statusline"
    if [ ! -x "$TARGET" ]; then
      command -v cargo >/dev/null || { echo "error: cargo needed to build the native binary" >&2; exit 1; }
      echo "→ building native binary…"
      ( cd "$HERE" && cargo build --release --manifest-path native/Cargo.toml >/dev/null )
    fi
  else
    TARGET="$HERE/statusline-command.sh"
  fi
fi
[ -e "$TARGET" ] || { echo "error: target not found: $TARGET" >&2; exit 1; }

# ── Detect kind (script vs native ELF) ───────────────────────────────
if   [ "$NATIVE" = 1 ];                 then KIND=native
elif [ "${TARGET##*.}" = sh ];          then KIND=script
elif command -v file >/dev/null 2>&1 && file -b "$TARGET" 2>/dev/null | grep -q ELF; then KIND=native
else KIND=script; fi

# ── Layout mode ──────────────────────────────────────────────────────
# Default (ENGINE on): a REPRESENTATIVE (moderate, not maximal) custom template —
# a layout a real user would plausibly write: a few fields across mixed formats
# (short, effort, folder, two bars, dur, usd), two {?}…{/} conditional groups, a
# smart {sep}, and a couple color tokens. Exercises the full tokenize + ONE
# dynamic-jq extract + format dispatch without being a kitchen-sink stress test.
# --template=… overrides it; --no-template leaves CLAUDE_STATUSLINE_FIELDS empty
# to measure the default hardcoded fast path instead.
ENGINE_TEMPLATE='{bright_green}[{json.model.display_name:short}]{reset}{json.effort.level:effort} {bright_white}{json.workspace.current_dir:folder}{reset}{?json.context_window.used_percentage} ctx {json.context_window.used_percentage:bar}{/}{?json.rate_limits.five_hour.used_percentage} 5h {json.rate_limits.five_hour.used_percentage:bar}{/} {sep} {json.cost.total_duration_ms:dur} {json.cost.total_cost_usd:usd}'
TEMPLATE=""
if [ "$ENGINE" = 1 ]; then
  if [ -n "$TEMPLATE_ARG" ]; then TEMPLATE="$TEMPLATE_ARG"; else TEMPLATE="$ENGINE_TEMPLATE"; fi
fi
# Exported so BOTH the bash script (inherited by `bash "$TARGET"`) and the native
# binary (getenv) see it. Empty = the default/hardcoded path. /usr/bin/true and
# the empty `floor` bin ignore it, so the spawn-floor comparison is unaffected.
export CLAUDE_STATUSLINE_FIELDS="$TEMPLATE"

# ── Sample envelope (resets_at relative so the countdown is sane) ────
now=$(printf '%(%s)T' -1 2>/dev/null || date +%s)
ENVF=$(mktemp)
jq -nc --argjson r "$((now + 9000))" '{
  model:{display_name:"Claude Opus 4.8"}, session_id:"bench",
  workspace:{current_dir:"/home/me/projects/demo"},
  context_window:{used_percentage:42},
  cost:{total_cost_usd:11.55,total_duration_ms:4560000},
  rate_limits:{five_hour:{used_percentage:85,resets_at:$r},seven_day:{used_percentage:10}},
  effort:{level:"high"}}' > "$ENVF"

# One render. Script: throttle OFF = full render (honest worst case).
# Native: as-is (it has no throttle).
runonce() {
  if [ "$KIND" = native ]; then "$TARGET" < "$ENVF"
  else CLAUDE_STATUSLINE_THROTTLE=0 bash "$TARGET" < "$ENVF"; fi
}

echo "Claude Code status line benchmark"
echo "  target:     $TARGET  [$KIND]"
echo "  iterations: $ITERS"
if [ -n "$TEMPLATE" ]; then
  echo "  layout:     ENGINE — custom template (full tokenize + dynamic jq + format dispatch)"
else
  echo "  layout:     default (hardcoded fast path; engine short-circuited)"
fi
echo "  sample out: $(runonce)"
# Guard: if --engine but the target renders the template identically to its
# default output, the target doesn't honor CLAUDE_STATUSLINE_FIELDS (e.g. a stale
# installed script predating the engine) — the numbers would be mislabeled.
if [ -n "$TEMPLATE" ]; then
  if [ "$KIND" = native ]; then _def=$(CLAUDE_STATUSLINE_FIELDS= "$TARGET" < "$ENVF")
  else _def=$(CLAUDE_STATUSLINE_FIELDS= CLAUDE_STATUSLINE_THROTTLE=0 bash "$TARGET" < "$ENVF"); fi
  [ "$(runonce)" = "$_def" ] && echo "  ! WARN: engine output == default — target ignores CLAUDE_STATUSLINE_FIELDS (stale install?); pass the repo script/binary as the target."
fi
[ "$KIND" = script ] && echo "  (main metrics = FULL render, throttle disabled)"
echo

have_epoch=0; [ -n "${EPOCHREALTIME:-}" ] && have_epoch=1
# Capture "now" in microseconds into the variable named by $1. Uses `printf -v`
# so there is NO command substitution: a per-iteration `t=$(now_us)` forks a
# subshell, and at two samples per iteration that injects ~1 ms of bash-fork
# overhead — enough to make /bin/true and a ~1 ms binary read as identical and to
# bury every startup A/B (musl, opt-level) under harness noise. (The `10#` guard
# parses the leading-zero fractional field as decimal, not octal.)
# (internal var is __us, not e/s, so callers can pass "e"/"s" without shadowing it)
if [ "$have_epoch" = 1 ]; then
  now_us_to() { local __us=$EPOCHREALTIME; printf -v "$1" %s $(( ${__us%.*} * 1000000 + 10#${__us#*.} )); }
else
  now_us_to() { printf -v "$1" %s $(( $(date +%s%N 2>/dev/null || echo "$(date +%s)000000000") / 1000 )); }
fi

# Min wall-microseconds of "<cmd> < $ENVF" over <iters> spawns. MIN, not mean, is
# the noise-resistant estimator for sub-millisecond spawn deltas (one scheduler
# hiccup blows up the mean but not the min).
min_us_of() {
  local n=$1; shift; local mn=0 s e d i
  for ((i=0; i<n; i++)); do
    now_us_to s; "$@" < "$ENVF" >/dev/null 2>&1; now_us_to e
    d=$(( e - s )); { [ "$i" = 0 ] || [ "$d" -lt "$mn" ]; } && mn=$d
  done
  printf '%s' "$mn"
}

# ── Wall time ────────────────────────────────────────────────────────
min=0 max=0 sum=0
for ((i=0; i<ITERS; i++)); do
  now_us_to s; runonce >/dev/null; now_us_to e
  d=$(( e - s )); sum=$(( sum + d ))
  [ "$i" = 0 ] && { min=$d; max=$d; }
  [ "$d" -lt "$min" ] && min=$d; [ "$d" -gt "$max" ] && max=$d
done
awk -v s="$sum" -v n="$ITERS" -v mn="$min" -v mx="$max" 'BEGIN{
  printf "Wall time:  %.2f ms/run   (min %.2f, max %.2f)   [%d runs in %.2fs]\n",
         s/n/1000, mn/1000, mx/1000, n, s/1000000 }'

# ── Spawn floor comparison: how much of the wall is "being a process" (native) ──
# Times /usr/bin/true and `floor` (an empty-main Rust bin, same release profile +
# static linking) next to the real binary. The point is that our binary spawns at
# essentially the floor — the ~6 µs of logic is below the spawn-noise floor. Sub-ms
# deltas are noisy, so we report the MIN (one scheduler hiccup wrecks a mean, not a
# min). Note /usr/bin/true is usually *dynamically* linked, so our static binary can
# spawn faster than it — that's the point, not a measurement error.
if [ "$KIND" = native ]; then
  FLOOR="$(dirname "$TARGET")/floor"; TRUE=""
  for t in /usr/bin/true /bin/true; do [ -x "$t" ] && { TRUE=$t; break; }; done
  if [ -n "$TRUE" ] && [ -x "$FLOOR" ]; then
    an=$(( ITERS < 2000 ? ITERS : 2000 ))
    at=$(min_us_of "$an" "$TRUE"); af=$(min_us_of "$an" "$FLOOR"); ab=$(min_us_of "$an" "$TARGET")
    awk -v tr="$at" -v fl="$af" -v bn="$ab" -v n="$an" 'BEGIN{
      printf "Spawn floor (min of %d; sub-ms deltas are noisy — min is the robust estimator):\n", n;
      printf "  /usr/bin/true (system, usually dynamic): %.3f ms\n", tr/1000;
      printf "  empty static Rust bin (floor):           %.3f ms\n", fl/1000;
      printf "  this binary (read+parse+render+write):   %.3f ms\n", bn/1000;
      printf "  → vs the empty static bin: %+.3f ms — the ~6 µs of logic is below spawn noise.\n", (bn-fl)/1000 }'
  fi
fi

# ── CPU time + usage % ───────────────────────────────────────────────
cpu_line=$( { for ((i=0; i<ITERS; i++)); do runonce >/dev/null; done; times; } 2>/dev/null | tail -1 )
cpu_total_s=$(awk -v line="$cpu_line" 'BEGIN{
  split(line, a, " "); for (j in a){ m=a[j]; sub(/m.*/,"",m); s=a[j]; sub(/.*m/,"",s); sub(/s/,"",s); tot+=m*60+s }
  printf "%.6f", tot }')
awk -v cpu="$cpu_total_s" -v wall_us="$sum" -v n="$ITERS" 'BEGIN{
  if (cpu<=0){ print "CPU time:   n/a"; exit } wall=wall_us/1000000;
  printf "CPU time:   %.2f ms/run   (user+sys, summed over %d runs)\n", cpu*1000/n, n;
  printf "CPU usage:  %.0f%% of one core while running   (CPU %.2fs / wall %.2fs)\n", cpu/wall*100, cpu, wall;
  printf "            %.3f%% of one core averaged at refreshInterval 60s (idle duty cycle)\n", (cpu/n)/60*100 }'

# ── Peak RAM (fork-free VmHWM poll) ──────────────────────────────────
if [ -r /proc/self/status ]; then
  hwm_of() { local m=0 k v _; while [ -r "/proc/$1/status" ]; do
    while read -r k v _; do [ "$k" = "VmHWM:" ] && [ "$v" -gt "$m" ] && m=$v; done 2>/dev/null < "/proc/$1/status" || true
  done; echo "$m"; }
  if [ "$KIND" = native ]; then
    "$TARGET" < "$ENVF" >/dev/null 2>&1 & p=$!; kb=$(hwm_of "$p"); wait "$p" 2>/dev/null
    awk -v k="$kb" 'BEGIN{ printf "Peak RAM:   %.1f MB   (single process, transient — 0 resident between runs)\n", k/1024 }'
  else
    bash "$TARGET" < "$ENVF" >/dev/null 2>&1 & p=$!; bkb=$(hwm_of "$p"); wait "$p" 2>/dev/null
    jq . "$ENVF" >/dev/null 2>&1 & p=$!; jkb=$(hwm_of "$p"); wait "$p" 2>/dev/null
    awk -v b="$bkb" -v j="$jkb" 'BEGIN{ printf "Peak RAM:   ~%.1f MB momentary  (bash %.1f MB + jq %.1f MB, transient)\n", (b+j)/1024, b/1024, j/1024 }'
  fi
else echo "Peak RAM:   n/a (needs Linux /proc)"; fi

# ── External processes per run ───────────────────────────────────────
if [ "$KIND" = native ]; then
  echo "External processes/run: 0  (no bash, no jq — single binary)"
elif command -v mktemp >/dev/null; then
  shim=$(mktemp -d); fc="$shim/.count"; : > "$fc"
  for cmd in jq git date stat cksum basename awk cat tail cut sed; do
    real=$(command -v "$cmd" 2>/dev/null) || continue
    printf '#!/usr/bin/env bash\necho %s >> "%s"\nexec "%s" "$@"\n' "$cmd" "$fc" "$real" > "$shim/$cmd"; chmod +x "$shim/$cmd"
  done
  PATH="$shim:$PATH" CLAUDE_STATUSLINE_THROTTLE=0 bash "$TARGET" >/dev/null < "$ENVF"
  echo "External processes/run: $(wc -l < "$fc" | tr -d ' ')  [$(sort "$fc" | uniq -c | tr '\n' ' ' | tr -s ' ')]"
  rm -rf "$shim"
fi

# ── Script-only: throttled fast-path ─────────────────────────────────
if [ "$KIND" = script ]; then
  echo
  cache="${TMPDIR:-/tmp}/claude-statusline-out-bench"; rm -f "$cache"
  CLAUDE_STATUSLINE_THROTTLE=3600 bash "$TARGET" < "$ENVF" >/dev/null   # prime
  fsum=0
  for ((i=0; i<ITERS; i++)); do
    now_us_to s; CLAUDE_STATUSLINE_THROTTLE=3600 bash "$TARGET" < "$ENVF" >/dev/null; now_us_to e; fsum=$(( fsum + e - s ))
  done
  awk -v s="$fsum" -v n="$ITERS" 'BEGIN{ printf "Throttled fast-path: %.2f ms/run   (cached reprint, no jq)\n", s/n/1000 }'
  rm -f "$cache"
fi
rm -f "$ENVF"
