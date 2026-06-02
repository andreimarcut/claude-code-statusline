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
  Uses `#![no_main]` + a C `main` to skip std's `lang_start` (stack-overflow guard + SIGPIPE
  handler) for startup-syscall savings; it therefore flushes stdout explicitly.
- `native/src/bin/bench.rs` — a SEPARATE `bench` bin (not wired into `main`) that times
  each stage with warmup + `black_box`. Run: `cargo run --release --bin bench`.
- `native/src/bin/floor.rs` — a dev-only empty-`main` bin (same release profile). `bench.sh`
  times it between `/usr/bin/true` and the real binary to show spawn ≫ logic. Never shipped.

If you change the **rendering** (fields, order, colors, glyphs, separators, formats),
change BOTH `statusline-command.sh` and `lib.rs`, then run `./parity-check.sh` (it diffs
the script with `CLAUDE_STATUSLINE_THROTTLE=0` against the built binary across 14 envelopes;
`BIN=<path> ./parity-check.sh` checks a specific artifact, e.g. the musl build).
Notes:
- The binary intentionally has **no throttle** (sub-ms render; a cache round-trip would
  only add cost) and **omits the legacy transcript ctx fallback** (pre-2.1.132 only).
- Zero external crates by design (offline build, tiny binary) — keep it dependency-free;
  the parser in `lib.rs` is a proper recursive-descent parser, not regex.
- The logic is ~6 µs/call; ~99% of a real invocation is process startup (warm spawn ~0.4 ms),
  so don't bother micro-optimizing the code — there's nothing there to win. `bench.sh`'s
  "Spawn floor" rows show the binary spawns at the empty-static-bin floor; logic is below noise.
- Build: `cargo build --release --manifest-path native/Cargo.toml` (add `--target
  x86_64-unknown-linux-musl` for the musl build). Always build with the repo root as CWD so
  `.cargo/config.toml` is found (the scripts use `( cd "$HERE" && cargo … )`).
- **Static linking**: `.cargo/config.toml` (repo root) sets `-C target-feature=+crt-static`,
  scoped to `cfg(target_os = "linux")` (so macOS — no static libc — and aarch64-linux behave)
  — no dynamic linker at startup; safe (no NSS/DNS/getpw). `install.sh --native` **prefers the
  musl target when installed** (`rustup target add x86_64-unknown-linux-musl`): ~431 KB vs
  ~1.07 MB glibc (2.5× smaller), RELATIVE relocs 1475→400 + IRELATIVE 23→0, and ~12% faster
  warm spawn (~0.05 ms — real but sub-0.1 ms; footprint is the bigger win). It also requires
  an x86_64-Linux host (`install.sh` gates on `uname -sm` so the target isn't picked on a
  non-x86_64-Linux box). Falls back to the host target — still statically linked on Linux
  hosts; macOS gets the default dynamic libSystem link (the `cfg(target_os = "linux")` scope
  above excludes it).
- **`bench.sh` timing**: it captures `$EPOCHREALTIME` into plain vars via `printf -v`. Do
  NOT reintroduce `t=$(now_us)` command substitution — each `$(...)` forks a subshell, and at
  two/iteration that adds ~0.5 ms of phantom overhead that buries every sub-ms A/B (this is
  why the old harness reported ~1.1 ms for a binary that actually warm-spawns in ~0.4 ms).

### Evaluated and rejected (don't re-explore — measured, not guessed)

A multi-agent brainstorm vetted ~22 candidate optimizations against the ~0.4 ms warm spawn
(logic is ~6 µs). Only the musl target moved real wall-clock; these were measured and
**rejected** — don't re-propose without new evidence:
- **Daemon/socket front-end or native session cache** — *net regression* (+0.5…+2.3 ms):
  Claude Code still forks a client each call, and a warm cache round-trip ≈ the 6 µs render
  it would replace. (A `SessionStart` `cat ~/.claude/claude-statusline >/dev/null` page-cache
  prewarm for the cold first call is the only legitimate keep-resident lever.)
- **`target-cpu=native` / PGO / `build-std`** — recompile only the 6 µs logic (can't touch
  glibc's prebuilt IFUNC resolvers); PGO breaks the one-command offline build; `build-std`
  is nightly (breaks stable-Rust). Keep them out of the default build.
- **Static no-PIE** (`relocation-model=static`) — ~10 µs, sign not robust above noise, costs
  ASLR; subsumed by musl (which already cuts relocations).
- **Logic micro-opts** (single preallocated render `String`, gradient-escape consts,
  pre-sized Vecs, `Cow`/zero-copy parser, `skip_value`, hand-rolled `itoa`) — all sub-noise;
  `itoa`/integer-cents `%.2f` also **breaks parity** (round-half-away vs Rust/bash's
  round-half-to-even). The in-process logic is not worth optimizing.
- **Strip `.eh_frame` / `-z norelro` / self-provided `mem*`** — demand-paged dead bytes or
  sub-µs; some flags break under rust-lld. No runtime payoff; subsumed by musl.

## Install it for the user

**First, offer the choice (use AskUserQuestion): bash script vs native binary.**
- **Script** (default, recommend this): needs `jq` + bash 4.2+, no build, portable,
  trivially auditable. ~6 ms / ~1.8 ms throttled, ~6 MB.
- **Native**: ~0.4 ms warm spawn, ~0.4 MB (musl) / ~1 MB (glibc), zero forks — but needs
  `cargo` and a one-time build, and is platform-specific. `install.sh --native` prefers the
  musl target when installed. Pick only if the user wants the minimal footprint and has `cargo`.
Both render identically; the status line runs ≤ ~once/second, so the difference is
footprint, not felt speed. Default to the script unless they ask otherwise; check the
chosen front-end's prerequisites first and stop with install instructions if missing.

Then run the installer for their choice:
- Script: `./install.sh` (copies the script to `~/.claude/statusline-command.sh`, merges
  the `statusLine` block, backs up settings first).
- Native: `./install.sh --native` (builds `native/` — preferring the musl static target if
  `rustup` has it — and points the command at `~/.claude/claude-statusline`; falls back to
  the script if `cargo` is absent).
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
