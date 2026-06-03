# Write-ups & posts

Narrative content about building this status line — the **bash → native Rust → musl**
evolution, the **benchmarking**, **all the optimizations** (kept and rejected), and the
**89-agent adversarial brainstorm** used to find them.

Synthesized from this repo's git history, `CLAUDE.md`/`README.md`, the `bench.sh`/`native/`
sources, and the project's Claude Code session transcripts. The four posts are written in
**Radu's own voice** — reverse-engineered from his published work (Medium, rencfs, xorio.rs,
dev.to, Substack) into [`style-guide.md`](style-guide.md) — and each is shaped to the format
its platform actually renders (see the table).

## Files

| File | Platform | Length / tone |
|---|---|---|
| [`linkedin-post.md`](linkedin-post.md) | LinkedIn **feed** | Tight (~2,360 chars, under the ~3,000 feed limit). Lead image: `assets/01-journey.png`. |
| [`linkedin-article.md`](linkedin-article.md) | LinkedIn **Article** (Pulse) | The full long-form version (no char limit) — paste into LinkedIn's Article editor. |
| [`reddit-post.md`](reddit-post.md) | r/rust · r/programming · r/commandline | Candid, technical, dead-ends-forward. Title + body. |
| [`substack-article.md`](substack-article.md) | Substack | Long-form essay (~1,800 words). Full narrative arc. |
| [`devto-article.md`](devto-article.md) | dev.to | Code-heavy tutorial/story hybrid. Has YAML frontmatter. |
| [`benchmark-data.md`](benchmark-data.md) | — | **Resource:** every number, the build comparison, the full rejected-ideas ledger. The source of truth the four posts draw from. |
| [`style-guide.md`](style-guide.md) | — | **Resource:** the author's voice (tone, habits, signature phrases) reverse-engineered from his published work, used to write the posts. |

## Images (`assets/`)

Square (1080×1080), dark/terminal-themed — built for the LinkedIn feed (carousel or single image).

| File | Use |
|---|---|
| [`assets/01-journey.png`](assets/01-journey.png) | Hero: `73 ms → 0.34 ms`, bash→native, log scale, musl highlighted |
| [`assets/02-where-time-goes.png`](assets/02-where-time-goes.png) | The hook: `~334 µs spawn (98%)` vs `~6 µs logic (2%)` |
| [`assets/03-funnel.png`](assets/03-funnel.png) | `169 ideas → 22 → 6 → 1 (musl)` + the rejected dead-ends |
| [`assets/six-workflow-patterns.png`](assets/six-workflow-patterns.png) | The dynamic-workflow patterns diagram (credit: @trq212) — referenced in the brainstorm section *Borrowed light-themed external figure, not part of the dark 1080×1080 chart set.* |
| `assets/_gen.py` | Pillow script that renders charts 01–03 (re-run to tweak) |

**LinkedIn suggestion:** lead with `01-journey.png`, or post 01→02→03 as a carousel (best reach).

## The story in one paragraph

A one-line status bar that runs once a second. The bash version forked `jq` 12× (~73 ms);
collapsing to one `jq` + builtins got it to ~6 ms (~1.8 ms cached). A zero-dependency Rust
rewrite revealed the real wall: the logic is **~6 µs** — ~99% of every run is process spawn.
So the wins moved to the spawn path: static linking (no `ld.so`), `#![no_main]` (skip
`lang_start`), a **musl** static build (431 KB, ~0.34 ms warm spawn), and an absolute exec
path (skip the `/bin/sh` wrapper). An **89-agent adversarial brainstorm** vetted 22 candidate
optimizations and kept ~6 — only musl moved measurable wall-clock; a daemon idea was 2.2×
*slower* and core-pinning was 10× *worse*. The biggest correction wasn't a speedup at all: the
benchmark was forking subshells per sample and overcounting by ~0.6 ms. Honest bottom line:
**the native edge is footprint, not felt speed** — the script stays the default.

## Notes before publishing

- Numbers are measured on Linux x86_64 / NVMe and reflect the latest best-run values in the repo.
- `devto-article.md` starts with `---` frontmatter (`published: false`) — flip to `true` when ready.
- The posts overlap by design (same facts, different framing/length per platform); they're meant
  to be published independently, not read back-to-back.

---

_Built with Claude Code — these docs and the charts were generated via Claude Code dynamic workflows._
