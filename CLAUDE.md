# CLAUDE.md — guidance for Claude Code working in this repo

This repo is a **Claude Code status line**: a bash script that Claude Code runs and
whose stdout is shown in the bottom bar. Your job when a user opens this repo is to help
them **install**, **customize**, or **extend** it. Keep edits faithful to the existing
style and the performance constraints below.

## The one file that matters

`statusline-command.sh` — reads a JSON envelope from **stdin** and prints one line.
Everything else (`install.sh`, `settings.example.json`, README, `EXTENDING.md`) is
packaging/docs.

## Install it for the user

Preferred: run `./install.sh` (copies the script to `~/.claude/statusline-command.sh`
and merges the `statusLine` block into `~/.claude/settings.json`, backing it up first).
`REFRESH_INTERVAL=<seconds> ./install.sh` sets the idle refresh.

Manual equivalent — copy the script to `~/.claude/`, then ensure `~/.claude/settings.json`
contains the block in `settings.example.json`. **Never blow away the user's settings.json**:
read it, set only the `.statusLine` key (use `jq`), back it up first.

Always verify after any change by piping a sample envelope through the script (see the
"Verify" section of README.md) and showing the rendered line.

## How the script works (so you edit it correctly)

1. `input=$(cat)` reads the whole envelope. **Do not** change this to `$(</dev/stdin)` —
   that reads empty under Claude Code's stdin piping and blanks every field.
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
- **Sonnet-only weekly %** → already wired: the `jq` step scans `rate_limits` for any key
  matching `sonnet` and shows a `son` segment if present. Current Claude Code does **not**
  put that bucket in the envelope (only `five_hour` + all-models `seven_day`), so it stays
  hidden until a future version adds it. It is NOT available from any local cache or CLI.

## Field source of truth

Available envelope fields: https://code.claude.com/docs/en/statusline#available-data
When unsure whether a field exists, capture a real envelope by temporarily adding
`jq -c 'paths(scalars)|join(".")' <<<"$input" > /tmp/sl-paths.txt` after `input=$(cat)`,
let the status line refresh, inspect, then remove the debug line.
