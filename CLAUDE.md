# CLAUDE.md — guidance for Claude Code working in this repo

This repo is a **Claude Code status line**: a bash script that Claude Code runs and
whose stdout is shown in the bottom bar. Your job when a user opens this repo is to help
them **install**, **customize**, or **extend** it. Keep edits faithful to the existing
style and the performance constraints below.

## The one file that matters

`statusline-command.sh` — reads a JSON envelope from **stdin** and prints one line.
Everything else (`install.sh`, `settings.example.json`, README, `EXTENDING.md`) is
packaging/docs.

### Native binary mirror (`native/`)

A Rust reimplementation that must stay **byte-identical** to the script's output (optional
fast path; users may run either). Layout:
- `native/src/lib.rs` — all the logic: JSON parser + `render(input, now)` (and the
  benchable pieces `parse`, `render_parsed`, `render_bar`). `render` is **pure** — `now`
  is passed in, not read from the clock — so it's deterministic and testable.
- `native/src/main.rs` — thin: read stdin → `render` → write. **Keep it clear** (no logic).
- `native/src/bin/bench.rs` — a SEPARATE `bench` bin (not wired into `main`) that times
  each stage with warmup + `black_box`. Run: `cargo run --release --bin bench`.

If you change the **rendering** (fields, order, colors, glyphs, separators, formats),
change BOTH `statusline-command.sh` and `lib.rs`, then run `./parity-check.sh` (it diffs
the script with `CLAUDE_STATUSLINE_THROTTLE=0` against the built binary across 14 envelopes).
Notes:
- The binary intentionally has **no throttle** (sub-ms render; a cache round-trip would
  only add cost) and **omits the legacy transcript ctx fallback** (pre-2.1.132 only).
- Zero external crates by design (offline build, tiny binary) — keep it dependency-free;
  the parser in `lib.rs` is a proper recursive-descent parser, not regex.
- The logic is ~7 µs/call; ~99% of a real invocation is process startup, so don't bother
  micro-optimizing the code — there's nothing there to win.
- Build: `cargo build --release --manifest-path native/Cargo.toml`.

## Install it for the user

**First, offer the choice (use AskUserQuestion): bash script vs native binary.**
- **Script** (default, recommend this): needs `jq` + bash 4.2+, no build, portable,
  trivially auditable. ~6 ms / ~1.7 ms throttled, ~6 MB.
- **Native**: ~1 ms, ~1–2 MB, zero forks — but needs `cargo` and a one-time build, and is
  platform-specific. Pick only if the user wants the minimal footprint and has `cargo`.
Both render identically; the status line runs ≤ ~once/second, so the difference is
footprint, not felt speed. Default to the script unless they ask otherwise; check the
chosen front-end's prerequisites first and stop with install instructions if missing.

Then run the installer for their choice:
- Script: `./install.sh` (copies the script to `~/.claude/statusline-command.sh`, merges
  the `statusLine` block, backs up settings first).
- Native: `./install.sh --native` (also builds `native/` and points the command at
  `~/.claude/claude-statusline`; falls back to the script if `cargo` is absent).
`REFRESH_INTERVAL=<seconds> ./install.sh` sets the idle refresh either way.

Manual equivalent — copy the script to `~/.claude/`, then ensure `~/.claude/settings.json`
contains the block in `settings.example.json`. **Never blow away the user's settings.json**:
read it, set only the `.statusLine` key (use `jq`), back it up first.

Always verify after any change by piping a sample envelope through the script (see the
"Verify" section of README.md) and showing the rendered line. After perf-relevant edits,
run `./bench.sh` and report wall time / CPU / peak RAM / forks before and after.

## How the script works (so you edit it correctly)

1. `IFS= read -rd '' input || true` reads the whole envelope with a builtin (no fork).
   **Do not** change this to `$(</dev/stdin)` — that reads empty under Claude Code's stdin
   piping and blanks every field. (`read -d ''` was verified to work against the live pipe;
   `$(cat)` also works but adds a fork.)
2. **One `jq` call** extracts all fields into bash variables. Fields are joined with an
   ASCII **Unit Separator (0x1f)**, not tab, because `IFS` treats tab as whitespace and
   would collapse consecutive separators, dropping absent fields and shifting every later
   column. `// ""` keeps absent fields as empty slots so the `read` stays aligned.
   **If you add or remove a field, update BOTH the `jq` array AND the `read` variable list,
   keeping them in the same order.**
3. The rest formats segments and joins them. Each rendered field is pushed to the `parts`
   array; the final loop joins `parts` with a single space.

## Performance constraints (the whole point of this script)

It targets ~15 ms/run because Claude Code calls it frequently. Preserve these:

- **Exactly one external program on the hot path: `jq`.** Use bash builtins instead of
  forking: `${var##*/}` not `basename`; `printf '%(%s)T' -1` not `date +%s`;
  `printf -v x '%.2f'` not `awk`; parameter expansion / arithmetic instead of `cut`/`expr`.
- **No `git`** — the folder is shown, the branch is not (removing the branch removed the
  only `git` call and its temp-file cache). Don't reintroduce `git` casually; if a user
  wants the branch back, cache it (see "Cache expensive operations" in the Claude Code
  docs) keyed on `session_id` — never on `$$`/PID.
- Guard every numeric field with a regex before arithmetic/printf so a malformed value
  yields an empty segment, not an error (the script runs under `set -u`).

## Common requests and how to handle them

- **Add a field** → add to the `jq` array + `read` list (same position), parse/guard it,
  build a colored segment, push to `parts`. See `EXTENDING.md` for a worked example.
- **Reorder fields** → reorder the `parts+=(...)` lines. Cost is intentionally last.
- **Change separators** → the join loop near the end (`line+=" "`).
- **Change bar width / colors** → `render_bar` (default width 5) and the `BAR_GRAD`
  256-color gradient table.
- **Idle refresh cadence** → `refreshInterval` in `settings.json` (seconds), not the script.
- **Throttle** → the script reprints its cached line and exits before `jq` if called within
  `CLAUDE_STATUSLINE_THROTTLE` seconds (default 2; `0` disables). Cache key = `session_id`
  (pulled with a bash regex, no jq) → `$TMPDIR/claude-statusline-out-<session_id>`. If you
  add the throttle logic anywhere, keep it BEFORE the `jq` parse or it saves nothing.
- **Sonnet-only weekly %** → already wired: the `jq` step scans `rate_limits` for any key
  matching `sonnet` and shows a `son` segment if present. Current Claude Code does **not**
  put that bucket in the envelope (only `five_hour` + all-models `seven_day`), so it stays
  hidden until a future version adds it. It is NOT available from any local cache or CLI.

## Field source of truth

Available envelope fields: https://code.claude.com/docs/en/statusline#available-data
When unsure whether a field exists, capture a real envelope by temporarily adding
`jq -c 'paths(scalars)|join(".")' <<<"$input" > /tmp/sl-paths.txt` after `input=$(cat)`,
let the status line refresh, inspect, then remove the debug line.
