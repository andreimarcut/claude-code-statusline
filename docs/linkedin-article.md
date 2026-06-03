# LinkedIn article (long-form / Pulse)

> Plain text — paste below the divider into LinkedIn's long-form **Article** editor (no ~3,000-char limit). For the short FEED post, use linkedin-post.md.

---

I spent way too long making a status line start 5 milliseconds faster. The most useful thing I learned was admitting most of that work didn't matter :)

It all started by accident. I stumbled on the /statusline command in Claude Code and wanted to see what it was even about. So I read the docs:
https://code.claude.com/docs/en/statusline

The docs show an example status line — two lines, model and folder and a little context bar — and honestly it looked nice.

[Attach image: docs/assets/default-statusline.png — Claude Code's default two-line status line — the docs example that started it]

And I got curious: could I make something similar, but one line and more compact?

Honest aside: all of this was vibe coding. I don't generally encourage that — but for experiments, PoCs, and little learning projects, it is great. This was exactly that.

A friend asked me to send him the config, so I quickly spun up a GitHub repo with Claude Code to share it. Side note, Claude Code's install-by-prompt is lovely — you hand it a prompt plus a repo and it installs everything for you, no copy-paste dance.

Then another friend in the same group said it was too slow :)) — and this was when it ran in ~6 ms. So I rewrote it in Rust. When it got down to ~1 ms, that same friend said: fast, you don't even feel it — but not the fastest it can be.

So I said "hold my beer," and went and ran a parallel brainstorm to push it even lower.

But first, how it got to ~1 ms in the first place.

First it was a bash script. The early version forked jq twelve times, once per field, and spent ~48 ms of its ~73 ms just spawning and tearing down processes. One jq call plus bash builtins got it to ~6 ms with a single fork. A cached fast-path took the common case to ~1.8 ms, zero forks.

Good enough for most people. But I wanted to know how low it could go, so I rewrote it in Rust. Hand-written JSON parser, zero dependencies, byte-for-byte identical output, checked across 14 envelopes.

Here is where it got interesting. The Rust logic runs in ~6 microseconds. Six. The other ~99% of every call is just the OS spawning a process. You can't out-code that — an empty fn main doesn't start any faster.

So the real game was startup, not code:

-> Static linking, no dynamic linker -> ~25-35% off spawn
-> Skipping Rust's runtime init with no_main -> a few syscalls gone
-> A musl static build -> 2.5x smaller (431 KB vs 1.07 MB), far fewer startup relocations (1475 -> 400)
-> An absolute path in the config so the OS execs the binary directly instead of routing through a shell -> ~0.7-0.9 ms

End result -> ~0.34 ms warm start, zero forks, under 1 MB.

Then the part I had the most fun with. I ran a structured brainstorm with 89 AI agents — some proposing optimizations, others adversarially trying to refute each one, all required to MEASURE, not argue. I actually ran three of these adversarial brainstorms in parallel, for variety and to cross-check each other, so the ~89 agents and the ideas are the totals across the three. 120 ideas, +49 from debate, curated down to 22 real candidates.

I ran it with Claude Code's new dynamic workflows, which is what made the fan-out / refute / curate dance possible in the first place:
https://claude.com/blog/introducing-dynamic-workflows-in-claude-code
https://x.com/trq212/status/2061907337154367865

The brainstorm itself was really just an instance of these patterns — fan-out to generate ideas, adversarial verification to refute them, generate-and-filter to curate what survived.

[Attach image: docs/assets/six-workflow-patterns.png — The six dynamic-workflow patterns (credit: @trq212). The brainstorm leaned on Fanout-and-Synthesize, Generate-and-Filter, and Adversarial Verification.]

And here is the actual prompt I kicked it off with, typos and all:

    /effort ultracode
    - analyze the whole flow for native and find ways to optimize even more, use also dynamic workflow
    - organize a brainstorming session between muliple agents, lunch several agents to emit ideas and other to refute them
    - most of the agents have them use Opus latest model but make some agents, randomly like 10-30% of them, use Sonnet latest model, for variety, and also have different effort levels selected for them also randomly between all agents like [high, xhigh, "ultracode", max]
    - run this for 30m and show me the results

The verdict on those 22 -> 6 kept, 16 rejected. And of the 6, only one actually moved the wall clock above noise: the musl build. A "keep the process resident behind a socket" idea ran ~2.2x slower (7.4 ms vs 3.3 ms). Pinning to a CPU core to cut variance made p50 latency ~10x worse on a hybrid CPU.

But hey, the single biggest correction wasn't a speedup at all. My own benchmark was lying. It timed each run with a shell construct that forked two subshells per measurement, inflating the number by ~0.8 ms. The "1.1 ms" I had been reporting was mostly the ruler, not the thing. Real number -> ~0.4 ms.

The honest takeaway, now right in the README -> the native edge is footprint, not felt speed. A status line that runs once a second doesn't care about 5 ms. Both versions are imperceptible.

What I'm taking with me -> measure the right layer (I optimized code for hours when 99% of the cost was the spawn). Validate the ruler before the thing you measure. And adversarial review beats brainstorming — the value wasn't the 169 ideas, it was the agents that killed most of them with evidence.

Don't get me wrong, I love a fast binary. But sometimes the best optimization is the rigor to prove you don't need one.

What I would try next: the refute stage stopped at argument — agents judged each candidate on paper. The natural next step is to let every surviving idea actually get built and benchmarked for real, in isolation, and pick the winner from measured data instead of a verdict. Dynamic workflows can already do this: give each agent its own git worktree, so a refute/implement stage spins up one worktree per candidate, implements it there, runs the benchmark in that worktree, and reports its numbers back, and the final pick is made from the real benchmark data across all the worktrees. And you don't need a separate "agent teams" feature for it — you can just instruct the dynamic workflow to do exactly that in the prompt.

What I find genuinely exciting is the whole family Claude Code has been shipping — subagents, an agent view, agent teams (https://code.claude.com/docs/en/agent-teams), programmatic MCP/API/CLI calls (similar in spirit to dynamic workflows but aimed at MCP/APIs/CLI and generating CLIs), and now dynamic workflows, which is basically agent logic running inside the agent. That last one is the powerful one: it's what let me express the fan-out -> refute -> curate dance, and it could express this worktree-benchmark-select loop just as naturally.

And a real thank you to the friends who watched this unfold in the group — especially the one who kept heckling the speed. That ribbing is what drove the whole thing; without his "too slow" and then his "still not the fastest," I would never have gone down this rabbit hole, and it turned into the most fun I have had benchmarking in a long time :)

The write-up, the bench harness, and the rejected-ideas ledger are all open source in the repo: https://github.com/radumarias/claude-code-statusline — Let the journey begin :)

#Rust #Performance #SoftwareEngineering #Benchmarking #OpenSource

Built with Claude Code — the code, the benchmarks, the charts, and this write-up.
