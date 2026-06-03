# Write-ups & posts

Narrative content about building this status line — the **bash → native Rust → musl**
evolution, the **benchmarking**, **all the optimizations** (kept and rejected), and the
**89-agent adversarial brainstorm** used to find them.

Synthesized from this repo's git history, `CLAUDE.md`/`README.md`, the `bench.sh`/`native/`
sources, and the project's Claude Code session transcripts.

## Files

| File | Platform | Length / tone |
|---|---|---|
| [`linkedin-post.md`](linkedin-post.md) | LinkedIn | Short, story-driven, professional. Lessons-forward. |
| [`reddit-post.md`](reddit-post.md) | r/rust · r/programming · r/commandline | Candid, technical, dead-ends-forward. Title + body. |
| [`substack-article.md`](substack-article.md) | Substack | Long-form essay (~1,800 words). Full narrative arc. |
| [`devto-article.md`](devto-article.md) | dev.to | Code-heavy tutorial/story hybrid. Has YAML frontmatter. |
| [`benchmark-data.md`](benchmark-data.md) | — | **Resource:** every number, the build comparison, the full rejected-ideas ledger. The source of truth the four posts draw from. |

## The story in one paragraph

A one-line status bar that runs once a second. The bash version forked `jq` 12× (~73 ms);
collapsing to one `jq` + builtins got it to ~6 ms (~1.8 ms cached). A zero-dependency Rust
rewrite revealed the real wall: the logic is **~6 µs** — ~99% of every run is process spawn.
So the wins moved to the spawn path: static linking (no `ld.so`), `#![no_main]` (skip
`lang_start`), a **musl** static build (431 KB, ~0.34 ms warm spawn), and an absolute exec
path (skip the `/bin/sh` wrapper). An **89-agent adversarial brainstorm** vetted 22 candidate
optimizations and kept ~6 — only musl moved measurable wall-clock; a daemon idea was 2.6×
*slower* and core-pinning was 10× *worse*. The biggest correction wasn't a speedup at all: the
benchmark was forking subshells per sample and overcounting by ~0.6 ms. Honest bottom line:
**the native edge is footprint, not felt speed** — the script stays the default.

## Notes before publishing

- Numbers are measured on Linux x86_64 / NVMe and reflect the latest best-run values in the repo.
- `devto-article.md` starts with `---` frontmatter (`published: false`) — flip to `true` when ready.
- The posts overlap by design (same facts, different framing/length per platform); they're meant
  to be published independently, not read back-to-back.
