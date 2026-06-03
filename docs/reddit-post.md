# Reddit post

> Best fit: r/rust (primary), r/programming, or r/commandline. Reddit rewards
> candor and technical depth over polish. Lead with the surprising finding, not
> the project. Drop the title into the title field, post the body as text.

---

**Title:** I optimized a CLI's startup from ~6 ms to ~0.34 ms, ran 89 agents to find more wins, and learned the benchmark was the biggest bug

**Body:**

Context: it's a tiny tool — a status line for Claude Code. Reads JSON on stdin, prints one colored line, exits. It runs very frequently, so startup cost actually matters. That made it a fun, honest target for "how low can process startup go," and the answer surprised me.

**Bash → native.** The original was a bash script that forked `jq` once per field (12×). That alone was ~48 ms of ~73 ms. One `jq` call + bash builtins for everything else (`${var##*/}`, `printf '%(%s)T'`, `printf -v`, `IFS= read -rd ''`) → ~6 ms, 1 fork. A session-keyed cache reprints in ~1.8 ms with zero forks.

Then I rewrote it in Rust to chase the floor: hand-rolled recursive-descent JSON parser, **zero crates**, byte-identical output verified by a parity check over 14 envelopes.

**The wall I hit:** the actual logic (parse + render) is **~6 µs**. The rendering you see on screen is rounding error. ~99% of every invocation is the kernel spawning a process. You can't optimize code that isn't the bottleneck — an empty `fn main(){}` spawns at the same speed.

So the real levers were all about *being a process*:

| build | size | warm spawn (min) | notes |
|---|---|---|---|
| dynamic PIE | ~334 KB | ~0.57 ms | maps libc via ld.so every launch |
| static glibc | ~1.07 MB | ~0.38 ms | no ld.so; 1475 + 23 self-relocs |
| **static musl** | **~431 KB** | **~0.34 ms** | no ld.so; 400 + 0 self-relocs |

Plus `#![no_main]` + a C `main` to skip std's `lang_start` (the stack-overflow guard + SIGPIPE handler), and — embarrassingly impactful — writing an **absolute** path into the config so the OS `execve`s the binary directly instead of through a `/bin/sh` wrapper (~0.7–0.9 ms; a leading `~` isn't exec-able).

**The 89-agent brainstorm.** I ran a structured multi-agent pass: agents propose optimizations, *other* agents adversarially try to refute each one, everyone has to measure. 120 ideas → +49 from debate → 22 curated candidates → judged through 3 lenses (impact / constraint / measurability), default-refuted.

Of 22 candidates, **6 kept, 16 rejected, and exactly one (musl) moved measurable wall-clock.** Highlights from the reject pile, because the dead-ends are the useful part:

- **Daemon/socket front-end to keep it resident:** net regression, ~2.6× slower (7.4 ms vs 3.3 ms). Claude Code forks a client per call anyway, so you pay spawn cost *plus* a round-trip.
- **`taskset` core-pinning to cut variance:** made p50 ~10× *worse* on a hybrid P/E-core CPU.
- **`target-cpu=native` / PGO / `build-std`:** only recompile the 6 µs logic; can't touch glibc's prebuilt IFUNC resolvers; PGO breaks the one-command offline build; build-std is nightly.
- **Static no-PIE, strip `.eh_frame`, `-z norelro`, self-provided `memcpy`:** all sub-noise or subsumed by musl, some cost ASLR/hardening.
- **Every logic micro-opt** (single preallocated `String`, `Cow` zero-copy parser, hand-rolled `itoa`): sub-µs. The `itoa`/integer-cents trick also **broke parity** — integer cents round half-away-from-zero, but Rust's and bash's `%.2f` round half-to-even, so `$2.675`-type values disagreed.

**The actual biggest finding was a benchmark bug.** I'd been reporting ~1.1 ms warm spawn. Turned out `bench.sh` timed each sample with `s=$(now_us); …; e=$(now_us)` — and each `$(...)` forks a subshell. Two per iteration. That phantom ~0.6–1.7 ms made `/bin/true` and my binary indistinguishable. Switching to `printf -v` capturing `$EPOCHREALTIME` (no fork) revealed the real number: ~0.4 ms. The ruler was wrong, not the thing.

(Bonus gotcha: `/usr/bin/true` is dynamically linked, so it spawns *slower* than my static binary — leading to confusing negative "binary minus floor" deltas until I added a same-profile empty-`main` Rust binary as the real baseline.)

**Honest conclusion, now in the README:** the native edge is **footprint, not felt speed.** A once-a-second status line does not care about 5 ms. Both versions are imperceptible. I kept the script as the default and the native binary as an opt-in for people who want a <1 MB, zero-fork footprint.

Repo has the full bench harness, the parity checker, and the rejected-ideas ledger. Happy to answer questions about any of the measurements — especially if someone has a lever I missed that actually beats the execve floor.
