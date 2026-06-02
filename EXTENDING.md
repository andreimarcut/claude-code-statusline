# Extending the status line

The script renders one line from the JSON envelope Claude Code sends on stdin. Adding,
removing, or reordering fields is mechanical once you know the three places involved.

> Tip: open this repo in Claude Code and just ask — e.g. *"add a segment showing lines
> added/removed this session"*. `CLAUDE.md` tells Claude exactly how to do it safely.

## The data flow

1. **`jq` array** (one call) — lists every field to extract, in order.
2. **`read` variable list** — names the bash variables receiving those fields, **same order**.
3. **`parts+=(...)` lines** — format each value into a colored segment and append it.

Fields are joined with ASCII `0x1f` and read with `IFS=$'\x1f\n'`, so absent fields stay
as empty slots and never shift columns. `// ""` in `jq` is what keeps the slot present.

## Worked example: add "lines changed" (`+156/-23`)

The envelope provides `cost.total_lines_added` and `cost.total_lines_removed`.

**1. Add to the `jq` array** (anywhere, but append to avoid renumbering — keep it aligned
with the `read` list):

```jq
    (.cost.total_lines_added // ""),
    (.cost.total_lines_removed // "")
```

**2. Add matching variables to the `read` list, same order:**

```bash
IFS=$'\x1f\n' read -r \
  model_full effort_level dir_cur dir_cwd session_id ctx_pct \
  transcript cost_usd duration_ms session_pct week_all_pct session_resets_at \
  week_sonnet_pct lines_added lines_removed \
  <<<"$( ... )"
```

**3. Build a segment and push it** (place where you want it in the order):

```bash
if [[ "$lines_added" =~ ^[0-9]+$ ]] || [[ "$lines_removed" =~ ^[0-9]+$ ]]; then
  parts+=("${G}+${lines_added:-0}${R}/${D}-${lines_removed:-0}${R}")
fi
```

**4. Verify** (must stay column-aligned — test full, minimal, and empty envelopes):

```bash
echo '{"model":{"display_name":"Opus"},"cost":{"total_lines_added":156,"total_lines_removed":23}}' \
  | bash statusline-command.sh; echo
```

## Removing a field

Delete its `parts+=(...)` line to stop showing it. You can leave the `jq`/`read` entries
(harmless) or remove all three together — if you remove from `jq`/`read`, remove the
matching slot in **both** so the remaining variables stay aligned.

## Rules of thumb

- **Keep `jq` array and `read` list in lockstep** (same count, same order).
- **One fork only** (`jq`) on a full render, zero on a throttled reprint. Use bash builtins
  for everything else (stdin via `read -d ''`, not `cat`) — see `CLAUDE.md`.
- **Guard numerics** with a regex before arithmetic/`printf` (`set -u` is on).
- **Color helpers:** `pct_color <n>` (green/yellow/red by severity) for plain numbers;
  `render_bar <pct> [width]` for a gradient bar. Color vars: `G W D Y C R`, reset `R`.
