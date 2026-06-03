# Substack article

> Long-form. Title + subtitle + body. Paste into Substack's editor; the `##`
> headers become section breaks. ~1,800 words. Optional images noted inline.

---

## The Six-Microsecond Program: chasing a CLI's startup floor, and the rigor of admitting you've hit it

### How a one-line status bar became a study in measuring the right thing — bash to Rust to musl, 89 agents, and a benchmark that was lying to me

---

There's a particular kind of programming pleasure in optimizing something that doesn't need it. No deadline, no user complaints — just you, a profiler, and the question *how low can this go?* This is the story of answering that question for a tool so small it's almost a joke, and discovering that the most valuable output wasn't a faster program. It was the discipline to prove that "faster" had stopped mattering several milliseconds ago.

The tool is a **status line** for Claude Code: the little bar at the bottom of the terminal that shows which model you're on, how much context you've used, your rate-limit budgets, and the session cost. It reads a JSON envelope on standard input and prints exactly one line:

```
[Opus] high  [my-project]  ctx ██░░░ 42%  5h ████░ 85% ↻2h30m  wk 10%  1h16m  $11.55
```

Then it exits. Claude Code re-runs it constantly — after every message, on a timer when idle — so its startup cost is paid over and over. That frequency is what turned a toy into a legitimate performance problem.

### Stage one: stop forking so much

The first version was a bash script, and it had a classic shell-scripting disease: it forked a subprocess for everything. It called `jq` — a separate program launch — once for *each* field it pulled out of the JSON. Twelve fields, twelve process spawns. Profiling showed roughly **48 milliseconds of its ~73 ms total was just `jq` starting and stopping.**

The fix was to think in terms of *forks*, the unit that actually costs money here. One `jq` invocation that emits every field at once, joined by an obscure separator (ASCII Unit Separator, 0x1F — because a tab would get collapsed by the shell's field splitting and silently drop empty fields). Then every other subprocess got replaced by a bash builtin:

- `basename "$dir"` → `${dir##*/}`
- `date +%s` → `printf '%(%s)T' -1`
- piping to `awk` for math → `printf -v result '%.2f'`
- reading stdin with `$(cat)` → the builtin `IFS= read -rd ''`

That last one has a subtle trap: the obvious `$(</dev/stdin)` reads *empty* under Claude Code's particular way of piping stdin, which would blank every field. You only learn that by testing against the real pipe, not a fake one.

Result: **~6 ms, one fork.** A small cache — reprint the last line if it's fresh, keyed on the session ID — took the common case to **~1.8 ms with zero forks.**

For any reasonable person, this is where the story ends. The thing runs once a second; six milliseconds is invisible. But I wanted the floor.

### Stage two: the rewrite, and the wall

So I reimplemented the whole thing as a native Rust binary. A hand-written recursive-descent JSON parser, **zero external crates** (so it builds offline and stays tiny), and — importantly — output that's *byte-for-byte identical* to the bash script, enforced by a parity checker that pipes 14 different envelopes through both and diffs them. If the binary and the script ever disagree by a single escape code, the build fails.

Then I profiled the Rust. And I hit the wall that reframes this entire essay.

The actual logic — parse the JSON, format the line, build the colored bars — runs in **about six microseconds.** Not milliseconds. Microseconds. I measured each stage with a million-iteration micro-benchmark: parsing is ~2,900 ns, rendering ~2,400 ns, the whole thing ~5,700 ns.

Everything else — and "everything else" is **~99% of every real invocation** — is the operating system *spawning a process*. Loading the executable, mapping its libraries, running the language runtime's startup code before `main` even begins, then tearing it all down.

This is the insight that should be tattooed on every performance engineer: **you cannot out-code a cost that isn't in your code.** An empty `fn main(){}` compiled with the same settings starts at the same speed as my fully-functional binary. The render loop was never the problem. The problem was being born.

### Stage three: optimizing *being a process*

Once the target shifts from "the code" to "the spawn," a different toolbox opens:

**Static linking.** A dynamically-linked binary, at every single launch, invokes the dynamic linker (`ld.so`) to find and map shared libraries. Statically link it — bake libc in — and that entire dance disappears. Worth ~25–35% of spawn time. (Safe here only because the binary does no hostname/user lookups, which are the things that secretly need dynamic libc.)

**Skip the runtime preamble.** Rust's standard `main` is wrapped in `lang_start`, which installs a stack-overflow guard and a SIGPIPE handler before your code runs. Using `#![no_main]` with a C-style entry point skips it — a handful of syscalls saved. (Safe because our output line is small enough that a single `write` is atomic.)

**Switch to musl.** Statically linking glibc, ironically, *bloated* the binary to 1.07 MB. The musl libc produces a **431 KB** static binary instead — 2.5× smaller — and with dramatically fewer startup relocations to process (1,475 down to 400; another category from 23 down to zero).

**Use an absolute path.** This one's almost funny. The config that tells Claude Code what to run originally used a `~`-relative path. But the kernel's `execve` doesn't expand `~` — so a tilde-prefixed command silently gets routed through a `/bin/sh` wrapper, which means you pay for a *whole bash startup* (~0.7–0.9 ms) just to launch your 0.3 ms binary. Writing the absolute path makes the OS exec it directly.

The cumulative result:

| build | size | warm start | forks |
|---|---|---|---|
| bash script | — | ~6 ms (~1.8 throttled) | 1 / 0 |
| dynamic Rust | 334 KB | ~0.57 ms | 0 |
| static glibc | 1.07 MB | ~0.38 ms | 0 |
| **static musl** | **431 KB** | **~0.34 ms** | **0** |

### Stage four: 89 agents, and the value of being refuted

Here's where I did something unusual. Rather than keep guessing at optimizations, I ran a structured brainstorm using a swarm of ~89 AI agents with one rule: *some of you propose ideas, others adversarially try to kill them, and nobody wins an argument without a measurement.*

The pipeline produced 120 raw ideas, then 49 more from a debate round — 169 in total — curated down to **22 real candidates.** Each candidate was then judged through three adversarial lenses: does it have *impact*, does it respect the project's *constraints*, and is the effect *measurable above noise*? Default verdict: refuted. An idea survived only if the skeptics couldn't kill it.

Of 22 candidates: **6 kept, 16 rejected, and exactly one — the musl build — actually moved the wall clock in a way you could measure.** Crucially, these agents didn't just argue. They compiled real binaries, inspected them with `readelf`, traced syscalls with `gdb` catchpoints, and counted page faults with `getrusage`.

The reject pile is more instructive than the keep pile:

- A **daemon behind a socket** to keep the program resident — the kind of "obvious" win you'd whiteboard in a meeting — measured **2.6× slower** (7.4 ms vs 3.3 ms). Claude Code forks a client process per call regardless, so you pay spawn cost *plus* a socket round-trip to replace six microseconds of work.
- **Pinning the process to a CPU core** to reduce timing variance made median latency roughly **10× worse** on a modern hybrid (performance/efficiency-core) CPU.
- **CPU-specific codegen, profile-guided optimization, recompiling the standard library** — all only touch the six microseconds of logic, can't touch glibc's precompiled internals, and variously break the offline build or require nightly Rust.
- A dozen micro-optimizations of the render path — preallocated strings, zero-copy parsing, a hand-rolled integer-to-string routine — all sub-microsecond. The hand-rolled number formatter had a worse sin: it **broke output parity**, because integer-cents arithmetic rounds half-away-from-zero while both Rust's and bash's `%.2f` round half-to-*even*. A `$2.675` would disagree.

Six microseconds of logic. None of the code optimizations could ever matter, and the swarm proved it one refutation at a time.

### The twist: the benchmark was the bug

The single most consequential discovery in this entire project was not a speedup. It was that my benchmark had been lying to me.

I'd been confidently reporting **~1.1 ms** warm spawn for the native binary. But the benchmark harness timed each sample like this: `start=$(now_us); run_the_thing; end=$(now_us)`. And in bash, every `$(...)` **forks a subshell.** Two per measurement. That phantom overhead — easily 0.6 to 1.7 ms — was so large it made `/bin/true` and my optimized binary statistically *indistinguishable*. I had been measuring the ruler, not the object.

Replacing it with `printf -v` capturing the `$EPOCHREALTIME` variable directly — no fork — revealed the truth: **~0.4 ms.** The README now carries a permanent confession to this effect. As I wrote in my notes at the time: *the biggest single correction wasn't a speedup at all — the benchmark itself was overcounting by ~0.6 ms.*

(There was a companion gotcha: `/usr/bin/true`, my naive baseline, is *dynamically* linked, so it actually spawns *slower* than my static binary — producing nonsensical negative "binary minus baseline" numbers until I built a same-settings empty-`main` Rust binary to serve as an honest floor.)

### What it was actually about

Final tally: the binary warm-starts in ~0.34 ms, with zero forks, in under half a megabyte. It is, by any measure, fast.

And it does not matter. A status line that runs once a second is imperceptible whether it takes 6 ms or 0.3 ms. The honest conclusion, which now lives in the project's own documentation, is that **the native edge is footprint, not felt speed.** I kept the humble bash script as the default and made the native binary an opt-in for people who specifically want a tiny, zero-fork footprint.

So what was the point? Three things I'll carry into work that *does* matter:

**Measure the right layer.** I spent hours optimizing code that was 1% of the cost. The expensive thing was process spawn, and no amount of cleverness in the render function could touch it. Find the dominant cost before you optimize anything.

**Trust your benchmark last.** The most embarrassing bug wasn't in the program; it was in the instrument. Before you believe a number, validate the thing producing it. A ruler that forks two subshells per measurement will confidently report fiction.

**Adversarial review beats brainstorming.** The 169 ideas were cheap. The value was in the agents whose only job was to *kill* ideas with evidence — and who killed 163 of them. A good skeptic with a compiler is worth a hundred enthusiastic suggestions.

The smallest programs make the best teachers, precisely because there's nowhere for a sloppy assumption to hide. Six microseconds of logic, and a year's worth of lessons about everything around it.

---

*The full source, benchmark harness, parity checker, and the complete ledger of rejected optimizations are in the repository. If you've got a lever that genuinely beats the `execve` floor, I'd love to see the measurement.*
