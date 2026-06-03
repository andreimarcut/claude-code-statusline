# LinkedIn post

> Tone: professional, story-driven, a little contrarian. Short paragraphs.
> Paste as-is; trim if you want it shorter. Suggested 1 image: the bench.sh
> "spawn floor" output or the script→native comparison table.

---

I spent way too long making a status line start 5 milliseconds faster. Here's what I learned about optimization — and why the most valuable result was admitting most of it didn't matter.

The project is small: a one-line status bar for Claude Code. It reads a JSON blob on stdin and prints `[Opus] high  ctx ██░░░ 42%  5h ████░ 85%  $11.55`. Claude Code runs it constantly, so speed matters.

It started as a bash script. The first version forked `jq` twelve times — once per field — and spent ~48 ms of its ~73 ms just creating and tearing down processes. Collapsing that to a single `jq` call and replacing every other subprocess with a bash builtin (`${var##*/}` instead of `basename`, `printf '%(%s)T'` instead of `date`) got it to ~6 ms with one fork. A cached fast-path took the common case to ~1.8 ms with zero forks.

Good enough? For most people, yes. But I wanted to know how low it could go — so I rewrote it as a native Rust binary. Hand-written JSON parser, zero dependencies, byte-for-byte identical output (enforced by a parity check across 14 sample inputs).

That's where it got interesting. The Rust *logic* runs in ~6 microseconds. Six. The other ~99% of every invocation is just the operating system spawning a process. You cannot out-code that. An empty `fn main(){}` doesn't start any faster.

So the real game was startup, not code:
→ Static linking (no dynamic linker at launch): ~25–35% off spawn
→ Skipping Rust's runtime init with `#![no_main]`: a few more microseconds of syscalls gone
→ Switching to a musl static build: 2.5× smaller binary (431 KB vs 1.07 MB), far fewer startup relocations
→ Writing an absolute path into the config so the OS execs the binary directly instead of routing it through a shell: ~0.7–0.9 ms

End result: ~0.34 ms warm start, zero forks, under 1 MB.

Then I did something I'd recommend to anyone serious about performance work: I ran a structured brainstorm with ~89 AI agents — some proposing optimizations, others adversarially trying to refute each one, all required to *measure* rather than argue. 120 ideas, then 49 more from debate, curated to 22 real candidates.

The verdict on those 22? Exactly **one** moved the wall clock in a way you could measure above noise: the musl build. The other 21 were either sub-noise micro-optimizations or actively harmful. A "keep the process resident behind a socket" idea ran 2.6× *slower*. Pinning to a CPU core to reduce variance made latency 10× *worse* on a hybrid CPU.

And the single biggest correction wasn't a speedup at all — it was discovering my own benchmark was lying. It timed each run with a shell construct that forked two subshells per measurement, inflating the number by ~0.6 ms. The "1.1 ms" I'd been reporting was mostly the ruler, not the thing being measured. Real number: ~0.4 ms.

The honest takeaway, which I now put right in the README: **the native edge is footprint, not felt speed.** A status line that runs once a second does not care about 5 milliseconds. Both versions are imperceptible.

Three lessons I'm taking with me:
1. Measure the right layer. I optimized code for hours when 99% of the cost was process spawn.
2. Trust your benchmark last. Validate the ruler before the thing you're measuring.
3. Adversarial review beats brainstorming. The value wasn't the 169 ideas — it was the agents that killed 163 of them with evidence.

Full write-up, benchmark harness, and the rejected-ideas ledger are in the repo. Sometimes the best optimization is the rigor to prove you don't need one.

#Rust #Performance #SoftwareEngineering #Benchmarking #Bash #Optimization
