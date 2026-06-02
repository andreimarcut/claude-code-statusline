# claude-code-statusline

A compact, single-line [Claude Code](https://code.claude.com) status line that shows
model + effort, the current folder, **context** and **5-hour** usage as colored
gradient bars, the weekly quota, elapsed time, and session cost.

![Status line demo](assets/screenshot.png)

```
[Opus] high [claude-code-statusline] ctx ▓▓░░░ 27% 5h ▓▓░░░ 30% ↻42m wk 6% 7m22s $4.55
```

- **`[Opus] high`** — model (shortened) + reasoning effort, color-coded by level.
- **`[tmp]`** — current folder (dim brackets).
- **`ctx █░░░░ 19%`** — context-window usage as a bar. Fill color is a smooth
  green→yellow→orange→red gradient: greener when low, redder as it fills.
- **`5h ██░░░ 31% ↻3h49m`** — 5-hour rate-limit usage + time until it resets.
- **`wk 10%`** — weekly (all-models) rate-limit usage.
- **`1h16m`** — session elapsed time.
- **`$11.55`** — estimated session cost (last column).

Everything is read from the JSON envelope Claude Code pipes to the script on stdin —
no network calls, no API tokens consumed.

## Requirements

- **bash 4.2+** (uses `printf '%(%s)T'` and float `printf`; macOS ships 3.2 — see note below)
- **jq** (`brew install jq` / `apt install jq` / `pacman -S jq`)

> **macOS note:** the system bash is 3.2 and won't run this. Install a modern bash
> (`brew install bash`) — the `statusLine.command` already invokes `bash` from your
> `PATH`, so once Homebrew bash is first on `PATH` it just works. (Alternatively, point
> the command at `/opt/homebrew/bin/bash`.)

## Install

### Option A — one command

```bash
git clone https://github.com/radumarias/claude-code-statusline.git
cd claude-code-statusline
./install.sh
```

This copies `statusline-command.sh` to `~/.claude/` and merges the `statusLine` block
into `~/.claude/settings.json` (backing it up first, preserving all your other settings).
Set a different idle refresh with `REFRESH_INTERVAL=300 ./install.sh`.

### Option B — manual

1. Copy the script:
   ```bash
   cp statusline-command.sh ~/.claude/statusline-command.sh
   chmod +x ~/.claude/statusline-command.sh
   ```
2. Add this to `~/.claude/settings.json` (see `settings.example.json`):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline-command.sh",
       "refreshInterval": 60
     }
   }
   ```
3. Restart Claude Code (or just interact) — it picks up the change on the next update.

### Verify

```bash
echo '{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"/home/me/proj"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":0.08,"total_duration_ms":423000},"rate_limits":{"five_hour":{"used_percentage":85},"seven_day":{"used_percentage":4}},"effort":{"level":"high"}}' \
  | bash ~/.claude/statusline-command.sh; echo
```

## When does it run?

Claude Code runs the script **on events** (after each assistant message, after
`/compact`, on permission-mode or vim-mode changes; debounced ~300 ms) **and** on a
fixed `refreshInterval` timer. The timer mainly matters when the session is **idle** —
it keeps the elapsed-time and reset countdown current. Tune it:

- `refreshInterval: 60` — refresh once a minute when idle (default here).
- Lower (e.g. `5`) = snappier idle clock, more wakeups. Higher (e.g. `300`) = fewer.
- Event-driven updates during active work are unaffected by this value.

## Customize

A few knobs without touching logic:

- **Bar width** — `render_bar` defaults to 5 cells; pass a width, e.g.
  `render_bar "$ctx_pct" 8`.
- **Separator** — fields are joined with a single space in the final loop
  (`line+=" "`). Swap for `"${SEP}"` (a dim `·`) or `"  "` (two spaces).
- **Context window size fallback** — if your Claude Code is old enough that it doesn't
  send `context_window.used_percentage`, the script estimates from the transcript using
  a 1M default; override with `CLAUDE_STATUSLINE_CTX_MAX=200000`.
- **Colors** — see the `# ── Colors ──` block and the `BAR_GRAD` gradient table.

See [`EXTENDING.md`](EXTENDING.md) for adding/removing fields, and
[`CLAUDE.md`](CLAUDE.md) — open this repo in Claude Code and it already knows how to
set up, modify, and extend the status line for you.

## How it's built (performance notes)

It's deliberately cheap (~15 ms/run): the whole JSON envelope is parsed in **one** `jq`
call (fields joined with an ASCII Unit Separator so absent fields don't shift columns),
and every other helper is a bash builtin (no `date`/`basename`/`awk`/`cksum`/`stat`
forks). There's no `git` call. See the comments in `statusline-command.sh`.

## Field reference

All fields come from the [status line JSON input](https://code.claude.com/docs/en/statusline#available-data).
The script reads: `model.display_name`, `effort.level`, `workspace.current_dir`/`cwd`,
`context_window.used_percentage`, `cost.total_cost_usd`, `cost.total_duration_ms`,
`rate_limits.five_hour.{used_percentage,resets_at}`, `rate_limits.seven_day.used_percentage`,
and (when a future Claude Code version exposes it) a Sonnet-only weekly bucket.

## License

MIT — see [LICENSE](LICENSE).
