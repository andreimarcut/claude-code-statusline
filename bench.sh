#!/usr/bin/env bash
# Benchmark the Claude Code status line: wall time, CPU, CPU%, peak RAM, forks.
# Works for BOTH the bash script and the native binary.
#
# Usage:
#   ./bench.sh                       # 200 iters, auto-find the installed target
#   ./bench.sh 500                   # custom iteration count
#   ./bench.sh 500 /path/to/target   # explicit script (.sh) OR native binary
#   ./bench.sh --native              # build native/ if needed, then bench it
#   ./bench.sh --native 500
#
# Requires bash 5+ (EPOCHREALTIME) and jq. Peak-RAM and fork-count are
# Linux-only (/proc); they degrade gracefully elsewhere.
set -u
export LC_ALL=C   # '.' decimal separator in EPOCHREALTIME

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE=0; pos=()
for a in "$@"; do case "$a" in --native) NATIVE=1 ;; *) pos+=("$a") ;; esac; done
ITERS="${pos[0]:-200}"; TARGET="${pos[1]:-}"

command -v jq >/dev/null || { echo "error: jq required" >&2; exit 1; }

# ── Resolve target ───────────────────────────────────────────────────
if [ -z "$TARGET" ]; then
  if [ "$NATIVE" = 1 ]; then
    TARGET="$HERE/native/target/release/claude-statusline"
    if [ ! -x "$TARGET" ]; then
      command -v cargo >/dev/null || { echo "error: cargo needed to build the native binary" >&2; exit 1; }
      echo "→ building native binary…"
      cargo build --release --manifest-path "$HERE/native/Cargo.toml" >/dev/null
    fi
  elif [ -x "$HOME/.claude/statusline-command.sh" ]; then
    TARGET="$HOME/.claude/statusline-command.sh"
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
echo "  sample out: $(runonce)"
[ "$KIND" = script ] && echo "  (main metrics = FULL render, throttle disabled)"
echo

have_epoch=0; [ -n "${EPOCHREALTIME:-}" ] && have_epoch=1
now_us() {
  if [ "$have_epoch" = 1 ]; then local e=$EPOCHREALTIME; echo $(( ${e%.*} * 1000000 + 10#${e#*.} ))
  else echo $(( $(date +%s%N 2>/dev/null || echo "$(date +%s)000000000") / 1000 )); fi
}

# ── Wall time ────────────────────────────────────────────────────────
min=0 max=0 sum=0
for ((i=0; i<ITERS; i++)); do
  s=$(now_us); runonce >/dev/null; e=$(now_us)
  d=$(( e - s )); sum=$(( sum + d ))
  [ "$i" = 0 ] && { min=$d; max=$d; }
  [ "$d" -lt "$min" ] && min=$d; [ "$d" -gt "$max" ] && max=$d
done
awk -v s="$sum" -v n="$ITERS" -v mn="$min" -v mx="$max" 'BEGIN{
  printf "Wall time:  %.2f ms/run   (min %.2f, max %.2f)   [%d runs in %.2fs]\n",
         s/n/1000, mn/1000, mx/1000, n, s/1000000 }'

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
    s=$(now_us); CLAUDE_STATUSLINE_THROTTLE=3600 bash "$TARGET" < "$ENVF" >/dev/null; e=$(now_us); fsum=$(( fsum + e - s ))
  done
  awk -v s="$fsum" -v n="$ITERS" 'BEGIN{ printf "Throttled fast-path: %.2f ms/run   (cached reprint, no jq)\n", s/n/1000 }'
  rm -f "$cache"
fi
rm -f "$ENVF"
