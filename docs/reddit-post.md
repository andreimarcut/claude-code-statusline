# Reddit post

> Best fit: r/rust (primary), also fine on r/programming or r/commandline. Paste the body in Markdown mode so the table and code render. Lead with the punchline, not the project — Reddit rewards candor over polish.

---

**Title:** I tried to optimize a CLI's startup from ~6 ms to ~0.34 ms, ran an 89-agent brainstorm to find more wins, and learned my benchmark was the biggest bug

**Body:**

> *Up front, to be fair: this post was written with Claude Code (AI) — as were the code, the benchmarks, and the charts. The voice is modeled on my own past, non-AI articles; the model followed a [style guide](https://github.com/radumarias/claude-code-statusline/blob/main/docs/style-guide.md) reverse-engineered from them. My human writing: [medium.com/@xorio42](https://medium.com/@xorio42).*

Hi, I want to share something I learned the hard way, because honestly the dead-ends turned out more useful than the win.

It all started by accident. I stumbled on the `/statusline` command in Claude Code and wanted to see what it was about. So I read the docs: https://code.claude.com/docs/en/statusline — and the docs show an example status line, two lines, that looked really nice.

![Claude Code's default two-line status line — the docs example that started it](assets/default-statusline.png)

> Image: Claude Code's default two-line status line — the docs example that started it.

And then I got curious: could I make something similar but **one line** and more compact? So I started poking at it.

Honest aside: all of it was vibe coding. I do NOT generally encourage that — but for experiments, PoCs, and learning projects, it's great, and this was exactly that.

A friend asked me to send him the config, so I quickly spun up a GitHub repo with Claude Code to share it. (Side note: Claude Code's install-by-prompt is lovely — you hand it a prompt plus a repo and it installs everything for you.) Then ANOTHER friend in the same group said it was too slow :)) — this when it ran in ~5-15 ms. So I rewrote it in Rust. When it got down to ~1 ms, that friend said: fast, you don't even feel it — but not the fastest it can be. So I said "hold my beer," and went and did the parallel brainstorm below to push it even lower.

The thing itself is tiny — a status line for Claude Code: it reads JSON on stdin, prints one colored line, exits. It runs *very* frequently, so startup cost actually matters — an honest target for "how low can process startup go", and hey, the answer surprised me.

**Bash → native.** The original was a bash script that forked `jq` once per field, 12 times. That alone was ~48 ms of ~73 ms. So I collapsed it to one `jq` call plus bash builtins for everything else (`${var##*/}`, `printf '%(%s)T'`, `printf -v`, `IFS= read -rd ''`) → **~6 ms**, 1 fork. A session-keyed cache reprints in **~1.8 ms** with zero forks.

![the one-line status line](assets/screenshot.png)

*What I built: one compact line — model, folder, context + 5-hour usage bars, weekly quota, elapsed time, and cost.*

Then I rewrote it in **Rust** to chase the floor. Hand-rolled recursive-descent JSON parser, **zero crates**, byte-identical output verified by a parity check over 14 envelopes. Doing the parser by hand instead of reaching for a crate was a great learning experience — I felt like a student again, and that's the best part.

**The wall I hit:** the actual logic (parse + render) is **~6 µs** (5,696 ns over a 1M-iter micro-bench). The rendering you see on screen is rounding error. **~99% of every invocation is the kernel spawning a process.** You can't optimize code that isn't the bottleneck — an empty `fn main(){}` spawns at the same speed. That was humbling.

So the real levers were all about *being a process*, not about the code:

| build | size | warm spawn (min) | self-relocs | notes |
|---|---|---|---|---|
| dynamic PIE | ~334 KB | ~0.57 ms | — | maps libc via `ld.so` every launch |
| static glibc | ~1.07 MB | ~0.38 ms | 1475 + 23 | no `ld.so` |
| **static musl** | **~431 KB** | **~0.34 ms** | **400 + 0** | no `ld.so`, far fewer relocs |

musl vs glibc is **2.5× smaller**, relocs 1475→400 and 23→0, and ~10–20% faster warm spawn — but only **~0.04–0.09 ms** in absolute terms, so footprint is the real win here. The one place size actually bites is the cold page-cache penalty: musl **+0.50 ms**, glibc **+0.78 ms** (musl faults ~3× fewer pages).

Plus `#![no_main]` + a C `main` to skip std's `lang_start` (the stack-overflow guard + SIGPIPE handler; safe here because the line is `< PIPE_BUF`, one atomic `write`). And — *embarrassingly impactful* — writing an **absolute** path into the config so the OS `execve`s the binary directly instead of through a `/bin/sh` wrapper (**~0.7–0.9 ms**; a leading `~` isn't exec-able).

**The 89-agent brainstorm.** I ran a structured multi-agent pass — agents propose optimizations, *other* agents adversarially try to refute each one, and everyone has to measure, not guess. Actually I ran THREE of these adversarial brainstorms in parallel, for variety and so they'd cross-check each other, so the 89 agents and 169 ideas below are the totals across all three. I ran it with Claude Code's new [dynamic workflows](https://claude.com/blog/introducing-dynamic-workflows-in-claude-code) (the [launch post](https://x.com/trq212/status/2061907337154367865) has a nice diagram), which is what made the whole fan-out / refute / curate dance possible without me babysitting it.

Here's the actual prompt I kicked it off with — typos and all, I'm leaving them in :)

```
/effort ultracode
- analyze the whole flow for native and find ways to optimize even more, use also dynamic workflow
- organize a brainstorming session between muliple agents, lunch several agents to emit ideas and other to refute them
- most of the agents have them use Opus latest model but make some agents, randomly like 10-30% of them, use Sonnet latest model, for variety, and also have different effort levels selected for them also randomly between all agents like [high, xhigh, "ultracode", max]
- run this for 30m and show me the results
```

The brainstorm itself turned out to be an instance of those workflow patterns — fan-out to generate ideas, adversarial verification to refute them, generate-and-filter to curate the survivors. Neat to watch it use the very patterns it was built on.

![The six dynamic-workflow patterns](assets/six-workflow-patterns.png)

> Diagram: [Six Workflow Patterns](https://x.com/trq212/status/2061907337154367865) — The six dynamic-workflow patterns (credit: @trq212). The brainstorm leaned on Fanout-and-Synthesize, Generate-and-Filter, and Adversarial Verification.

It went: **Brainstorm** (120 ideas, 14 lenses) → **Debate** (+49, so 169 raw) → **Curate** (→ 22 canonical) → **Refute** (each judged through 3 adversarial lenses — impact / constraint / measurability — default-refuted, survives only if a majority don't refute). The agents actually *built and measured*: real musl binaries, an empty-`main` floor, `readelf`, `gdb` catchpoints, `getrusage` fault counts.

Result: **22 canonical → 6 kept, 16 rejected, and exactly one (musl) moved measurable wall-clock.** The reject pile, because that's the useful part:

- **Daemon/socket front-end to keep it resident:** net regression, ~2.2× slower (7.4 ms vs 3.3 ms). Claude Code forks a client per call anyway, so you pay spawn cost *plus* a round-trip.
- **`taskset` core-pinning to cut variance:** made p50 **~10× worse** on a hybrid P/E-core CPU.
- **`target-cpu=native` / PGO / `build-std`:** only recompile the 6 µs logic; can't touch glibc's prebuilt IFUNC resolvers; PGO breaks the one-command offline build; `build-std` is nightly.
- **Static no-PIE, strip `.eh_frame`, `-z norelro`, self-provided `memcpy`:** all sub-noise or subsumed by musl, some cost ASLR/hardening.
- **Every logic micro-opt** (single preallocated `String`, `Cow` zero-copy parser, hand-rolled `itoa`): sub-µs. The `itoa`/integer-cents trick also **broke parity** — integer cents round half-away-from-zero, but Rust's and bash's `%.2f` round half-to-even, so `$2.675`-type values disagreed.

**But the actual biggest finding was a benchmark bug.** I'd been reporting ~1.1 ms warm spawn. Turned out `bench.sh` timed each sample with `s=$(now_us); …; e=$(now_us)` — and each `$(...)` **forks a subshell**. Twice per iteration. That phantom ~0.8–1.7 ms made `/bin/true` and my binary indistinguishable. Switching to `printf -v` capturing `$EPOCHREALTIME` (no fork) revealed the real number: **~0.4 ms**. So the biggest single correction in the whole project wasn't a speedup at all — my measuring tool was overcounting the entire time.

(Bonus gotcha: `/usr/bin/true` is dynamically linked, so it spawns *slower* than my static binary — which gave confusing negative "binary minus floor" deltas until I added a same-profile empty-`main` Rust binary as the real baseline.)

**Honest conclusion**, now in the README: the native edge is **footprint, not felt speed.** A once-a-second status line does not care about 5 ms — both versions are imperceptible. So I kept the bash script as the default (needs `jq`, trivially auditable) and the native binary as an opt-in for people who want a <1 MB, zero-fork footprint.

Don't get me wrong, I love that **Rust** let me get down to the `execve` floor and *see* it — learning Rust really was one of the best decisions of my life. But the lesson I'm taking is humbler: measure your measuring tool first.

And a big thank you to the friends who got me into this — the one who asked for the config in the first place, and especially the one who kept heckling the speed. That ribbing ("too slow", then "not the fastest it can be") is what drove the whole thing; this entire write-up exists because of that nudge, and I'm genuinely grateful for it. :)

**What I'd try next.** The refute stage stopped at argument — the agents judged each candidate optimization on paper, and a verdict decided whether it survived. The natural next step is to let each surviving idea actually get *built and benchmarked* for real, in isolation, and then pick the winner from measured data instead of from a verdict. And the nice thing is dynamic workflows can already do this: you can give each agent its own `git worktree`, so a refute/implement stage spins up one worktree per candidate (`isolation: worktree`), implements the idea there, runs the benchmark in that worktree, and reports its numbers back — and the final selection is made from the real benchmark data across all the worktrees. You don't need a separate "agent teams" feature for this either — you can just instruct the dynamic workflow to do exactly that in the prompt.

What I find genuinely exciting is that Claude Code has been shipping a whole family of these — subagents, an agent view, [agent teams](https://code.claude.com/docs/en/agent-teams), programmatic MCP/API/CLI calls (similar in spirit to dynamic workflows but aimed at MCP/APIs/CLI / generating CLIs), and now dynamic workflows — which is basically agent logic running inside the agent. That last one is the powerful one: it's what let me express the fan-out → refute → curate dance, and I would imagine it could express this worktree-benchmark-select loop just as naturally. Let the journey begin. :)

The [repo](https://github.com/radumarias/claude-code-statusline) has the full bench harness, the parity checker, and the rejected-ideas ledger. Happy to answer questions about any of the numbers — especially if someone has a lever I missed that actually beats the `execve` floor, the speedup would be neat I would imagine. :)
