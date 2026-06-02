#!/usr/bin/env bash
# Benchmark the Claude Code status line: wall time, CPU, peak RAM, and the
# number of external processes spawned per run.
#
# Usage:
#   ./bench.sh                       # 200 iterations, auto-find the script
#   ./bench.sh 500                   # custom iteration count
#   ./bench.sh 500 /path/to/script   # custom script path
#
# Requires: bash 5+ (for EPOCHREALTIME), jq. Peak-RAM and fork-count are
# Linux-only (need /proc); they degrade gracefully elsewhere.
set -u
export LC_ALL=C   # ensure '.' decimal separator in EPOCHREALTIME

ITERS="${1:-200}"
SCRIPT="${2:-}"
if [ -z "$SCRIPT" ]; then
  if [ -f "$HOME/.claude/statusline-command.sh" ]; then SCRIPT="$HOME/.claude/statusline-command.sh"
  else SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline-command.sh"; fi
fi
[ -f "$SCRIPT" ] || { echo "error: script not found: $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq required" >&2; exit 1; }

# A realistic envelope (resets_at is relative so the countdown is sane).
now=$(printf '%(%s)T' -1 2>/dev/null || date +%s)
PAYLOAD=$(jq -nc --argjson r "$((now + 9000))" '{
  model:{display_name:"Claude Opus 4.8"},
  session_id:"bench",
  workspace:{current_dir:"/home/me/projects/demo"},
  context_window:{used_percentage:42},
  cost:{total_cost_usd:11.55,total_duration_ms:4560000},
  rate_limits:{five_hour:{used_percentage:85,resets_at:$r},seven_day:{used_percentage:10}},
  effort:{level:"high"}
}')

echo "Claude Code status line benchmark"
echo "  script:     $SCRIPT"
echo "  iterations: $ITERS"
echo "  bash:       $BASH_VERSION"
echo "  sample out: $(printf '%s' "$PAYLOAD" | bash "$SCRIPT")"
echo

# Helper: integer microseconds from EPOCHREALTIME ("sec.usec", 6 frac digits).
have_epoch=0; [ -n "${EPOCHREALTIME:-}" ] && have_epoch=1
now_us() {
  if [ "$have_epoch" = 1 ]; then
    local e=$EPOCHREALTIME; echo $(( ${e%.*} * 1000000 + 10#${e#*.} ))
  else
    echo $(( $(date +%s%N 2>/dev/null || echo "$(date +%s)000000000") / 1000 ))
  fi
}

# ── Wall time ────────────────────────────────────────────────────────
min=0 max=0 sum=0
for ((i=0; i<ITERS; i++)); do
  s=$(now_us); printf '%s' "$PAYLOAD" | bash "$SCRIPT" >/dev/null; e=$(now_us)
  d=$(( e - s )); sum=$(( sum + d ))
  [ "$i" = 0 ] && { min=$d; max=$d; }
  [ "$d" -lt "$min" ] && min=$d
  [ "$d" -gt "$max" ] && max=$d
done
awk -v s="$sum" -v n="$ITERS" -v mn="$min" -v mx="$max" 'BEGIN{
  printf "Wall time:  %.1f ms/run   (min %.1f, max %.1f)   [%d runs in %.2fs]\n",
         s/n/1000, mn/1000, mx/1000, n, s/1000000 }'

# ── CPU time + usage % (user+sys, via the `times` builtin) ───────────
cpu_line=$( { for ((i=0; i<ITERS; i++)); do printf '%s' "$PAYLOAD" | bash "$SCRIPT" >/dev/null; done; times; } 2>/dev/null | tail -1 )
# `times` children line: "<u>m<u.s>s <s>m<s.s>s" → total CPU seconds.
cpu_total_s=$(awk -v line="$cpu_line" 'BEGIN{
  split(line, a, " ");
  for (j in a) { m=a[j]; sub(/m.*/,"",m); s=a[j]; sub(/.*m/,"",s); sub(/s/,"",s); tot+=m*60+s }
  printf "%.6f", tot }')
# wall total for the same batch is `$sum` microseconds, from the loop above.
awk -v cpu="$cpu_total_s" -v wall_us="$sum" -v n="$ITERS" 'BEGIN{
  if (cpu<=0) { print "CPU time:   n/a"; exit }
  wall=wall_us/1000000;
  printf "CPU time:   %.1f ms/run   (user+sys, summed over %d runs)\n", cpu*1000/n, n;
  printf "CPU usage:  %.0f%% of one core while running   (CPU %.2fs / wall %.2fs)\n",
         cpu/wall*100, cpu, wall;
  printf "            %.3f%% of one core averaged at refreshInterval 60s (idle duty cycle)\n",
         (cpu/n)/60*100 }'

# ── Peak RAM (Linux /proc) ───────────────────────────────────────────
# The runs are sub-10ms, so we measure the two processes involved
# separately with fork-free /proc reads (forking a poller would be slower
# than the process under test). The momentary tree peak ≈ their sum, since
# the parent bash is alive while its jq child runs.
#
# poll_hwm <launch-cmd...> : run it, busy-poll its VmHWM (peak RSS) with no
# forks, echo the peak in KB.
poll_hwm() {
  "$@" >/dev/null 2>&1 & local p=$! m=0 k v _
  while [ -r "/proc/$p/status" ]; do
    while read -r k v _; do [ "$k" = "VmHWM:" ] && [ "$v" -gt "$m" ] && m=$v; done < "/proc/$p/status" 2>/dev/null || true
  done
  wait "$p" 2>/dev/null
  echo "$m"
}
if [ -r /proc/self/status ]; then
  printf '%s' "$PAYLOAD" | bash "$SCRIPT" >/dev/null   # warm caches
  # The script's own bash process (give it a sample window via the payload pipe).
  bash_kb=$(poll_hwm bash "$SCRIPT" <<<"$PAYLOAD")
  jq_kb=$(poll_hwm jq -rn 'reduce range(0;200) as $i (0; .+$i)')
  tree_kb=$(( bash_kb + jq_kb ))
  awk -v t="$tree_kb" -v b="$bash_kb" -v j="$jq_kb" 'BEGIN{
    printf "Peak RAM:   ~%.1f MB momentary  (bash %.1f MB + jq %.1f MB, both transient)\n",
           t/1024, b/1024, j/1024 }'
  echo "            (0 MB resident between runs — nothing stays alive)"
else
  echo "Peak RAM:   n/a (needs Linux /proc)"
fi

# ── External processes per run (Linux; PATH-shim count) ──────────────
if command -v mktemp >/dev/null; then
  shim=$(mktemp -d); fc="$shim/.count"; : > "$fc"
  for cmd in jq git date stat cksum basename awk cat tail cut sed; do
    real=$(command -v "$cmd" 2>/dev/null) || continue
    printf '#!/usr/bin/env bash\necho %s >> "%s"\nexec "%s" "$@"\n' "$cmd" "$fc" "$real" > "$shim/$cmd"
    chmod +x "$shim/$cmd"
  done
  PATH="$shim:$PATH" bash "$SCRIPT" >/dev/null <<<"$PAYLOAD"
  echo "External processes/run: $(wc -l < "$fc" | tr -d ' ')  [$(sort "$fc" | uniq -c | tr '\n' ' ' | tr -s ' ')]"
  rm -rf "$shim"
fi
