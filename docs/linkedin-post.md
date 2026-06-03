# LinkedIn post (feed)

> Plain text — copy everything below the divider; LinkedIn renders no Markdown.
> Sized for the feed (~3,000-char limit). Suggested image: assets/default-statusline.png.
> For the full long-form version, see linkedin-article.md (use LinkedIn's Article editor).

---

Up front: AI-written with Claude Code; the voice is modeled on my own past, non-AI articles (medium.com/@xorio42).

It all started by accident :) I stumbled on the /statusline command in Claude Code and wanted to see what it was, so I read the docs: https://code.claude.com/docs/en/statusline

[Attach image: assets/default-statusline.png — caption: "Claude Code's default two-line status line — the docs example that started it"]

The docs show an example status line, two lines, that looked nice. I got curious: could I make something similar but one line and more compact? Honest aside — all of it was vibe coding. I don't generally encourage that, but for experiments, PoCs, and learning projects, it's great. A friend asked me to send the config, so I spun up a GitHub repo with Claude Code to share it (its install-by-prompt is lovely). Then another friend in the same group said it was too slow :)) — this when it ran in ~6 ms. So I rewrote it in Rust. When it got to ~1 ms, that friend said: fast, you don't even feel it — but not the fastest. So I said "hold my beer," and went to push it even lower.

[Attach image: docs/assets/screenshot.png — What I built: one compact line — model, folder, context + 5-hour usage bars, weekly quota, elapsed time, and cost.]

That is where it got humbling. The Rust logic runs in ~6 microseconds. The other ~99% of every run is just the OS spawning a process. You cannot out-code that — an empty fn main starts no faster.

So the real wins were all about being a process, not about the code:
-> static linking, so there is no dynamic linker at launch
-> skipping Rust's runtime init with no_main
-> a musl static build -> 431 KB, far fewer startup relocations
-> an absolute exec path, so the OS does not route the call through /bin/sh (~0.7-0.9 ms)

End result -> ~0.34 ms warm start, zero forks, under 1 MB.

Then the fun part. I ran three parallel adversarial brainstorms — ~89 agents across all three, agents proposing optimizations, others refuting them, all required to MEASURE, not argue — using Claude Code's new dynamic workflows:
https://claude.com/blog/introducing-dynamic-workflows-in-claude-code

Of 22 real candidates, exactly one moved the wall clock above noise (musl). A "keep it resident behind a socket" idea was ~2.2x slower. Pinning to a core was ~10x worse.

But the single biggest correction wasn't a speedup at all — my own benchmark was lying. It forked two subshells per measurement and inflated every number by ~0.8 ms. I was measuring the ruler, not the thing.

The honest takeaway, now right in the README -> the native edge is footprint, not felt speed. A status line that runs once a second does not care about 5 ms.

Three lessons: measure the right layer. Validate the ruler before the thing you measure. And adversarial review beats brainstorming — the value wasn't the 169 raw ideas, it was killing most of the 22 survivors with evidence.

Thank you to the friends who pushed this along — especially the one who kept heckling the speed. That ribbing is what drove the whole thing :)

Full write-up, bench harness, and the rejected-ideas ledger: https://github.com/radumarias/claude-code-statusline — Let the journey begin :)

#Rust #Performance #Benchmarking #OpenSource
