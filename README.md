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
- *(optional)* **cargo** — only for the [native fast path](#native-fast-path-optional)

> **macOS note:** the system bash is 3.2 and won't run this. Install a modern bash
> (`brew install bash`) — the `statusLine.command` already invokes `bash` from your
> `PATH`, so once Homebrew bash is first on `PATH` it just works. (Alternatively, point
> the command at `/opt/homebrew/bin/bash`.)

## Install

### First, pick a front-end: script or native

Both render the exact same line — choose how it runs:

| | **Bash script** (default) | **Native binary** |
|---|---|---|
| Needs | `jq` + bash 4.2+ | a Rust toolchain (`cargo`) + a one-time build |
| Build step | none | `cargo build` (done for you by `--native`) |
| Portability | runs anywhere | platform-specific (build locally) |
| Speed / RAM | ~6 ms (~1.7 ms throttled) / ~6 MB | ~1 ms / ~1–2 MB, zero forks |
| Auditability | plain shell, read it in a glance | Rust source in [`native/`](native/) |

**Recommendation: use the script.** The status line runs at most ~once a second, so the
native edge is footprint, not felt speed — both are imperceptible. Choose native only if
you specifically want the minimal footprint *and* have `cargo`. You can switch later by
re-running the installer. Each method below lets you pick.

### Option A — let Claude Code do it (easiest)

Paste this prompt into Claude Code (from any directory) and let it handle everything —
choice, clone, install, and verify. It follows this repo's [`CLAUDE.md`](CLAUDE.md).

```text
Install the Claude Code status line from
https://github.com/radumarias/claude-code-statusline

1. Ask me whether I want the bash SCRIPT (default; needs jq + bash 4.2+, no build) or
   the NATIVE binary (~1ms, ~1-2MB, zero forks — but needs `cargo` and a one-time build,
   and is platform-specific). Recommend the script unless I want the minimal footprint.
2. Check the prerequisites for my choice; if something's missing, tell me how to install
   it for my OS and stop.
3. Clone the repo into a temp directory (or reuse it if I'm already inside it).
4. Run `./install.sh` for the script, or `./install.sh --native` for the binary. It
   installs to ~/.claude/ and merges the `statusLine` block into ~/.claude/settings.json
   (back it up first; preserve all my other settings — touch only the .statusLine key).
5. Verify: pipe a realistic sample envelope through the installed command and show me the
   rendered line, plus the resulting .statusLine from ~/.claude/settings.json.
6. Tell me to restart or interact with Claude Code to see it live.
```

> Prefer a different idle refresh? Add: "use refreshInterval 300" (seconds) to the prompt.

### Option B — one command

```bash
git clone https://github.com/radumarias/claude-code-statusline.git
cd claude-code-statusline

./install.sh            # bash script (default — needs jq + bash 4.2+, no build)
# …or…
./install.sh --native   # build & use the native binary (needs cargo)
```

Either way it installs to `~/.claude/` and merges the `statusLine` block into
`~/.claude/settings.json` (backing it up first, preserving all your other settings).
`--native` falls back to the script if `cargo` isn't found. Set a different idle refresh
with `REFRESH_INTERVAL=300 ./install.sh`.

### Option C — manual

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

For the **native binary** instead: `cargo build --release --manifest-path native/Cargo.toml`,
copy `native/target/release/claude-statusline` to `~/.claude/`, and set the `statusLine`
`command` to `~/.claude/claude-statusline` (drop the `bash` prefix).

### Verify

**With Claude Code** — paste this if it's not showing or you want to confirm the install:

```text
Verify my Claude Code status line is installed correctly:
- Confirm ~/.claude/statusline-command.sh exists and is executable.
- Confirm ~/.claude/settings.json has a `statusLine` block pointing at it.
- Pipe a sample JSON envelope through the script and show me the rendered line.
- If anything is off (missing jq, bash too old, empty output, settings not applied),
  diagnose and fix it.
```

**By hand:**

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

- **Bar width** — change `_BARW=5` near the top (the precomputed `█`/`░` runs follow it),
  or pass a width as `render_bar`'s 3rd arg: `render_bar _ctxbar "$ctx_pct" 8`.
- **Separator** — fields are joined with a single space in the final loop
  (`line+=" "`). Swap for `"${SEP}"` (a dim `·`) or `"  "` (two spaces).
- **Context window size fallback** — if your Claude Code is old enough that it doesn't
  send `context_window.used_percentage`, the script estimates from the transcript using
  a 1M default; override with `CLAUDE_STATUSLINE_CTX_MAX=200000`.
- **Colors** — see the `# ── Colors ──` block and the `BAR_GRAD` gradient table.
- **Throttling** — see below.

### Throttling

Claude Code re-runs the script on every event (each assistant message, etc.) plus the
`refreshInterval` timer. To avoid re-rendering on every burst event, the script caches its
last output per session and, if called again within `CLAUDE_STATUSLINE_THROTTLE` seconds,
**reprints the cached line and exits before `jq`** — so a coalesced call costs ~2.5 ms and
**zero forks** instead of a full render.

- Default: **2 seconds**. Set the env var to change it, or to **`0` to disable** (always
  full-render). Configure it in `~/.claude/settings.json`:
  ```json
  "env": { "CLAUDE_STATUSLINE_THROTTLE": "2" }
  ```
- Trade-off: within the window the line shows the *previous* values (up to N seconds
  stale). At the default 2 s this is imperceptible; raise it to coalesce harder, lower or
  `0` for always-fresh.

See [`EXTENDING.md`](EXTENDING.md) for adding/removing fields, and
[`CLAUDE.md`](CLAUDE.md) — open this repo in Claude Code and it already knows how to
set up, modify, and extend the status line for you.

## How it's built (performance notes)

It's deliberately cheap: the whole JSON envelope is parsed in **one** `jq` call (fields
joined with an ASCII Unit Separator so absent fields don't shift columns), and everything
else is a bash builtin — stdin is read with `read -d ''` (not `cat`), and there's no
`date`/`basename`/`awk`/`cksum`/`stat`/`git` fork. A full render is a single `jq`; a
throttled reprint is zero forks. See the comments in `statusline-command.sh`.

## Native fast path (optional)

For the absolute minimum, the repo ships a tiny **Rust** reimplementation in
[`native/`](native/) that's byte-identical to the script's output but runs as a single
native binary — **no `bash`, no `jq`, no forks**. It builds with **zero external crates**
(a small hand-written JSON parser), so `cargo build` works offline and produces a ~350 KB
binary.

| | bash, full render | bash, throttled | **native binary** |
|---|---|---|---|
| Wall time | ~6 ms | ~1.7 ms | **~1.3 ms** (min ~0.9) |
| Peak RAM | ~5.7 MB | ~3.4 MB | **~1–2 MB** |
| Forks | 1 (`jq`) | 0 | **0** |

It doesn't need the throttle (a full render is already sub-millisecond, so a cache
round-trip would only add cost) — it always shows fresh values.

Best of 6× `./bench.sh --native 5000` on Linux x86_64 (Ryzen):

```
Wall time:  1.34 ms/run   (min 0.92, max 10.94)   [5000 runs in 6.70s]
CPU time:   0.79 ms/run   (user+sys, summed over 5000 runs)
CPU usage:  59% of one core while running   (CPU 3.94s / wall 6.70s)
            0.001% of one core averaged at refreshInterval 60s (idle duty cycle)
Peak RAM:   1.1 MB   (single process, transient — 0 resident between runs)
External processes/run: 0  (no bash, no jq — single binary)
```

(The per-run wall includes the benchmark's own timing overhead; the `min ~0.9 ms` is closer
to the binary's true single-shot cost. The occasional `max` spike is a scheduler hiccup,
not the binary.)

```bash
./install.sh --native        # builds it, points Claude Code at ~/.claude/claude-statusline
```

Requires a Rust toolchain (`cargo`). The binary is platform-specific, so `install.sh`
builds it locally; if `cargo` is absent it falls back to the bash script. The script and
binary are kept in lockstep — a parity check pipes the same envelopes through both.

## Benchmark

`bench.sh` measures wall time, CPU, CPU%, peak RAM, and forks. It **auto-detects** whether
the target is the bash script or the native binary and adjusts accordingly. Higher
iteration counts give steadier numbers. To compare the two fairly, run both back-to-back —
same harness, same timing overhead.

### Benchmark the bash script

```bash
./bench.sh                                 # 200 iters, auto-finds the installed target
./bench.sh 5000                            # more iterations = steadier
./bench.sh 5000 ./statusline-command.sh    # an explicit script path
```

```
  (main metrics below = FULL render, throttle disabled)

Wall time:  6.3 ms/run   (min 4.9, max 8.3)   [300 runs in 1.90s]
CPU time:   6.0 ms/run   (user+sys, summed over 300 runs)
CPU usage:  95% of one core while running   (CPU 1.81s / wall 1.90s)
            0.010% of one core averaged at refreshInterval 60s (idle duty cycle)
Peak RAM:   ~6.7 MB momentary  (bash 3.4 MB + jq 3.3 MB, both transient)
            (0 MB resident between runs — nothing stays alive)
External processes/run: 1  [ 1 jq ]

Throttled fast-path: 2.5 ms/run   (cached reprint, no jq)
  external processes/run: 0  []
```

### Benchmark the native binary

```bash
./bench.sh --native                        # builds native/ if needed, then benchmarks it
./bench.sh --native 5000                   # more iterations
./bench.sh 5000 ~/.claude/claude-statusline   # an already-installed binary
```

```
Wall time:  1.34 ms/run   (min 0.92, max 10.94)   [5000 runs in 6.70s]
CPU time:   0.79 ms/run   (user+sys, summed over 5000 runs)
CPU usage:  59% of one core while running   (CPU 3.94s / wall 6.70s)
            0.001% of one core averaged at refreshInterval 60s (idle duty cycle)
Peak RAM:   1.1 MB   (single process, transient — 0 resident between runs)
External processes/run: 0  (no bash, no jq — single binary)
```

The native binary has no throttle and zero forks, so those sections are skipped for it.
See [Native fast path](#native-fast-path-optional) for the side-by-side comparison.

The script's main metrics measure the **full render** (throttle off) — the honest worst case: a
single `jq` fork. The **throttled fast-path** is what a coalesced burst-call costs when the
throttle is on and the cache is warm: ~2.6 ms and **zero forks** — it reads stdin with a
bash builtin, matches the cache with a regex, reprints the last line, and never reaches
`jq` (see [Throttling](#throttling)). What's left is almost entirely bash interpreter
startup (~1.3 ms), which any shell-based status line pays. (CPU usage can read slightly
over 100% because the parent `bash` and the `jq` child briefly run on separate cores.)

### Why is "CPU usage" ~100%?

That number is **CPU time ÷ wall time during the run** — a ratio, not a sign the script
is heavy. It's high because the script does pure computation with almost no waiting: `jq`
parsing the envelope and bash formatting are CPU work, and the only I/O is reading a tiny
stdin pipe. No network, no disk seeks, no `sleep`, no `git` — nothing that blocks. When a
program never waits, wall time ≈ CPU time, so the ratio approaches 100% (and can read a
little *over* 100% when the parent `bash` and the `jq` child briefly run on two cores).

A *low* percentage here would actually be worse: it would mean the process spends its time
blocked (on network/disk/another process) while taking longer in real time. **High
utilization + short duration is ideal** — it does its work in one tight ~6 ms burst and
exits.

The number that reflects real system impact is the **duty cycle**: the script runs ~6 ms,
then the core is free for the next ~60 s, so the time-averaged load is about **0.010% of
one core** at `refreshInterval: 60` (scales inversely with the interval). In short: *~100% =
"efficient, no idle waiting, for 6 ms"; 0.010% = "negligible over time."*

Each run is a short-lived process: ~6 ms, a few MB of RAM while it runs, **nothing
resident between runs**, and at most one fork (a single `jq` on a full render; zero on a
throttled reprint — stdin is read with a bash builtin, not `cat`). At the default
`refreshInterval: 60` that's a negligible, periodic blip. (Wall/CPU/RAM need bash 5+;
peak-RAM and fork-count are Linux-only and degrade gracefully elsewhere.)

## Field reference

All fields come from the [status line JSON input](https://code.claude.com/docs/en/statusline#available-data).
The script reads:

- `model.display_name` — model name (shortened to Opus/Sonnet/Haiku)
- `effort.level` — reasoning effort, color-coded
- `workspace.current_dir` (falls back to `cwd`) — current folder
- `context_window.used_percentage` — context bar
- `cost.total_cost_usd` — session cost
- `cost.total_duration_ms` — session elapsed time
- `rate_limits.five_hour.used_percentage` — 5h usage bar
- `rate_limits.five_hour.resets_at` — 5h reset countdown
- `rate_limits.seven_day.used_percentage` — weekly (all-models) usage
- Sonnet-only weekly bucket — shown if/when a future Claude Code version exposes it

## License

MIT — see [LICENSE](LICENSE).
