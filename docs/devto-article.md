---
title: "Optimizing a CLI's startup to 0.34 ms: bash → Rust → musl, and why 99% of it didn't matter"
published: false
description: "A tiny status-line tool became a case study in process-spawn optimization, adversarial benchmarking, and the discipline of measuring the right layer."
tags: rust, performance, bash, cli
---

> The actual logic of this program runs in ~6 microseconds. Everything else — 99% of every run — is the OS spawning a process. This is the story of optimizing *that*, and of a benchmark that turned out to be the biggest bug.

It's a **status line** for Claude Code: reads a JSON envelope on stdin, prints one colored line, exits.

```
[Opus] high  [my-project]  ctx ██░░░ 42%  5h ████░ 85% ↻2h30m  wk 10%  1h16m  $11.55
```

It runs constantly — after every message, on an idle timer — so startup cost is paid over and over. Perfect target for "how low can spawn go?"

## 1. Bash: think in forks

The original forked `jq` once per field — 12 launches, ~48 ms of ~73 ms total. The fix is to count *forks* as the real currency.

**One `jq` call** for all fields, joined by ASCII Unit Separator (`0x1f`) — not a tab, because the shell's `IFS` collapses tabs and would drop empty fields:

```bash
IFS=$'\x1f' read -r model effort dir ctx five_h ... < <(
  jq -rj '[.model.display_name, .effort.level, .workspace.current_dir, ...]
          | join("")' <<<"$input"
)
```

**Replace every other subprocess with a builtin:**

```bash
folder=${dir##*/}            # not: basename "$dir"
now=$(printf '%(%s)T' -1)    # not: date +%s
printf -v cost '%.2f' "$raw" # not: echo | awk
IFS= read -rd '' input       # not: input=$(cat)   ← the stdin read, fork-free
```

> Gotcha: `input=$(</dev/stdin)` reads **empty** under Claude Code's stdin piping and blanks every field. Test against the real pipe, not a synthetic one.

Result: **~6 ms, 1 fork.** A session-keyed cache that reprints before the `jq` parse: **~1.8 ms, 0 forks.**

## 2. Rust: meet the wall

Rewrite as a native binary — hand-written recursive-descent JSON parser, **zero crates**, output byte-identical to the script (a `parity-check.sh` diffs both across 14 envelopes).

Then measure the logic with a million-iteration micro-bench:

```
parse JSON               ~2933 ns
render_parsed (format)   ~2373 ns
render (parse+format)    ~5696 ns   ← the whole logic: ~0.006 ms
render_bar (one bar)      ~309 ns
```

**~6 µs.** The render you see on screen is rounding error. ~99% of every invocation is process spawn. You can't optimize code that isn't the bottleneck — an empty `fn main(){}` spawns just as fast.

## 3. Optimize *being a process*

The levers are all in the spawn path, not the code.

**Static linking** — no `ld.so` mapping shared libs at launch (~25–35% off spawn):

```toml
# .cargo/config.toml — scoped to Linux (macOS has no static libc)
[target.'cfg(target_os = "linux")']
rustflags = ["-C", "target-feature=+crt-static"]
```

**Skip the runtime preamble** with `#![no_main]` — bypasses std's `lang_start` (stack-overflow guard + SIGPIPE handler):

```rust
#![no_main]

#[no_mangle]
pub extern "C" fn main(_argc: i32, _argv: *const *const u8) -> i32 {
    // read stdin → render → write → flush explicitly (no lang_start to do it for us)
    0
}
```

> Safe because the output line is `< PIPE_BUF`, so the single `write` is atomic.

**Switch to musl** — static glibc bloated the binary to 1.07 MB; musl is 431 KB with far fewer startup relocations:

| build | size | warm spawn (min) | self-relocs |
|---|---|---|---|
| dynamic PIE | ~334 KB | ~0.57 ms | — |
| static glibc | ~1.07 MB | ~0.38 ms | 1475 + 23 |
| **static musl** | **~431 KB** | **~0.34 ms** | **400 + 0** |

```bash
rustup target add x86_64-unknown-linux-musl
cargo build --release --target x86_64-unknown-linux-musl
```

**Use an absolute path** in the config — a `~`-prefixed command isn't `execve`-able, so it gets routed through a `/bin/sh` wrapper (~0.7–0.9 ms of bash startup):

```jsonc
// settings.json — write the absolute path, NOT ~/.claude/...
"command": "/home/you/.claude/claude-statusline"
```

## 4. Benchmark adversarially: 89 agents

Instead of guessing further, I ran a structured multi-agent brainstorm: agents propose optimizations, *other* agents adversarially refute each one, everyone must measure. 120 ideas → +49 from debate → **22 curated candidates**, each judged through three lenses (impact / constraint / measurability), default-refuted.

**6 kept, 16 rejected. Exactly one — musl — moved measurable wall-clock.** The dead-ends are the lesson:

- **Daemon/socket front-end** (keep it resident): **2.6× slower** (7.4 ms vs 3.3 ms) — the client is forked per call anyway.
- **`taskset` core-pinning** (reduce variance): **~10× worse** p50 on a hybrid CPU.
- **`target-cpu=native` / PGO / `build-std`**: recompile only the 6 µs logic; can't touch glibc's prebuilt resolvers; break the offline/stable build.
- **Static no-PIE, strip `.eh_frame`, `-z norelro`, self-provided `memcpy`**: sub-noise or subsumed by musl.
- **Logic micro-opts** (preallocated `String`, zero-copy `Cow` parser, hand-rolled `itoa`): sub-µs — and `itoa`/integer-cents **broke output parity** (round-half-away vs `%.2f`'s round-half-to-even).

Freeze the wins so they can't regress:

```bash
# parity-check.sh hard-fails if the binary ever links dynamically
if file -b "$BIN" | grep -qi 'dynamically linked'; then
  echo "FAIL: $BIN is dynamically linked (expected static)." >&2
  exit 1
fi
```

## 5. The biggest bug was the benchmark

I'd been reporting **~1.1 ms** warm spawn. The harness timed each sample like this:

```bash
s=$(now_us); "$BIN" < "$ENV" >/dev/null; e=$(now_us)   # ← two $(...) = two forks
```

Each `$(...)` forks a subshell. **Two per iteration.** That phantom ~0.6–1.7 ms made `/bin/true` and the real binary indistinguishable. Fix — capture `$EPOCHREALTIME` with no fork:

```bash
printf -v s '%s' "$EPOCHREALTIME"; "$BIN" < "$ENV" >/dev/null; printf -v e '%s' "$EPOCHREALTIME"
```

Real warm spawn: **~0.4 ms.** *The biggest single correction wasn't a speedup — the benchmark was overcounting.*

> Bonus: `/usr/bin/true` is **dynamically linked**, so it spawns *slower* than the static binary — giving confusing negative "binary − baseline" deltas. The honest baseline is a same-profile empty-`main` Rust binary (`floor.rs`).

## The honest conclusion

~0.34 ms warm spawn, zero forks, <1 MB. And it doesn't matter: a once-a-second status line is imperceptible at 6 ms or 0.3 ms. **The native edge is footprint, not felt speed.** The bash script stays the default; the native binary is an opt-in for a tiny, zero-fork footprint.

Three takeaways:

1. **Measure the right layer.** 99% of the cost was spawn; the code was never the bottleneck.
2. **Trust your benchmark last.** Validate the ruler before the thing you measure.
3. **Adversarial review beats brainstorming.** 169 ideas were cheap; killing 163 with evidence was the value.

*Full source, harness, and rejected-ideas ledger in the repo. Got a lever that beats the `execve` floor? Show me the measurement.*
