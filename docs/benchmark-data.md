# Benchmark & optimization data (source of truth for the write-ups)

All figures measured on Linux x86_64 (16-core), NVMe SSD, with `bench.sh`.
"Warm spawn" = binary already in page cache. `min` is the robust single-shot
estimator (a high `max` is a scheduler hiccup, not the binary).

## The headline journey

| Stage | Wall / call | Forks | Footprint |
|---|---|---|---|
| Bash, original (12× `jq` forks) | ~73 ms (~48 ms was `jq`) | 12 | — |
| Bash, one `jq` + fork-free builtins | **~6 ms** (best 5.87) | 1 | ~6.7 MB transient |
| Bash, throttled fast-path (cached reprint) | **~1.8 ms** (best 1.76) | 0 | ~3.5 MB |
| Native, dynamic PIE | ~0.57 ms | 0 | ~334 KB |
| Native, static glibc | ~0.38 ms | 0 | ~1.07 MB |
| **Native, static musl (preferred)** | **~0.34 ms** | **0** | **~431 KB** |

In-process logic (1M-iter micro-bench): `render` (parse+format) ≈ **5,696 ns ≈ 0.006 ms**.
So **~99% of every invocation is process spawn**; ~6 µs is the actual logic.

## Native build comparison

| build | size | warm spawn (min) | self-relocations | startup |
|---|---|---|---|---|
| dynamic (PIE) | ~334 KB | ~0.57 ms | — | maps libc via `ld.so` every launch |
| static glibc | ~1.07 MB | ~0.38 ms | `R_X86_64_RELATIVE` 1475 + `IRELATIVE` 23 | no `ld.so` |
| **static musl** | **~431 KB** | **~0.34 ms** | **400 + 0** | no `ld.so`, far fewer relocs |

- musl vs glibc: **2.5× smaller**, relocs 1475→400 and 23→0, **~10–20% faster warm
  spawn** — but only **~0.04–0.09 ms** in absolute terms, so footprint is the bigger win.
- **Cold page-cache penalty** (the only regime where size matters): musl **+0.50 ms**
  (0.336→0.834), glibc **+0.78 ms** (0.402→1.179). musl faults ~3× fewer pages.

## Optimizations that shipped

1. **One `jq` call** instead of 12 (Unit-Separator-joined fields) — the foundational bash win.
2. **Fork-free builtins** — `${var##*/}` over `basename`, `printf '%(%s)T'` over `date`,
   `printf -v` over `awk`, `IFS= read -rd ''` over `$(cat)`. Full render → 1 fork; throttled → 0.
3. **Throttle/cache** keyed on sanitized `session_id` — reprint before `jq` if fresh.
4. **Native Rust port** — hand-written recursive-descent JSON parser, **zero external crates**,
   pure `render(input, now)` (clock injected → deterministic), `parity-check.sh` over 14 envelopes.
5. **Static linking** (`-C target-feature=+crt-static`, Linux-scoped) — removes `ld.so`, ~25–35% off spawn.
6. **`#![no_main]` + C `main`** — skips std's `lang_start` (stack-overflow guard + SIGPIPE handler);
   safe because the line is `< PIPE_BUF` (atomic single `write`).
7. **musl static target** — smaller binary, fewer relocs, smaller cold penalty.
8. **Absolute path in `settings.json`** — avoids the `/bin/sh` wrapper a `~`-path forces (**~0.7–0.9 ms**).
9. **Guardrails** — `parity-check.sh` hard-fails on a dynamically-linked binary; honest `bench.sh`
   harness; a dev-only empty-`main` `floor.rs` to attribute spawn vs logic.

## The multi-agent brainstorm

Invoked as an "ultracode" workflow: *launch agents to emit ideas, others to refute them.*
- **89 agents**, mixed models/effort, run as: **Brainstorm** (120 ideas, 14 lenses) →
  **Debate** (+49, 6 angles = 169 raw) → **Curate** (→ 22 canonical) →
  **Refute** (each judged through 3 adversarial lenses — impact, constraint, measurability —
  default-refuted; survives only if a majority of lenses don't refute).
- **Result: 22 canonical → 6 kept, 16 rejected.** Only **musl** moved measurable wall-clock.
- The agents **built and measured** (real musl binaries, an empty-`main` floor, `readelf`,
  `gdb` catchpoints, `getrusage` fault counts) rather than reasoning in the abstract.

### Rejected (measured, not guessed) — don't re-propose without new evidence
- **Daemon/socket front-end / native session cache** — *net regression* (~2.6× slower: 7.4 ms vs
  3.3 ms), because Claude Code forks a client each call anyway.
- **`target-cpu=native` / PGO / `build-std`** — recompile only the 6 µs logic; PGO breaks the
  offline build; `build-std` is nightly.
- **Static no-PIE** — ~10 µs, below noise, costs ASLR; subsumed by musl.
- **Logic micro-opts** (single preallocated `String`, gradient-escape consts, pre-sized Vecs,
  `Cow`/zero-copy parser, `skip_value`, hand-rolled `itoa`) — all sub-noise; `itoa`/integer-cents
  also **breaks parity** (round-half-away vs round-half-to-even).
- **Strip `.eh_frame` / `-z norelro` / self-provided `mem*`** — demand-paged dead bytes or sub-µs.
- **`taskset` core-pinning** (to reduce variance) — made p50 **~10× worse** on the hybrid CPU.

## The most consequential "bug": the benchmark itself

The README once cited **~1.1 ms** warm spawn. That was the *measuring tool*: `bench.sh` timed
each sample with `s=$(now_us); …; e=$(now_us)` — each `$(...)` **forks a subshell**, twice per
iteration, injecting ~0.8–1.7 ms of phantom overhead and making `/bin/true` and the real binary
indistinguishable. Fix: capture `$EPOCHREALTIME` directly via `printf -v` (no fork). True warm
spawn is **~0.4 ms**. *The biggest single correction wasn't a speedup — the benchmark was overcounting.*

## Recommendation

**Default to the bash script.** The status line runs ≤ ~once/second, so the native edge is
**footprint, not felt speed** — both render byte-identically. Choose native only for minimal
footprint when `cargo` is available.
