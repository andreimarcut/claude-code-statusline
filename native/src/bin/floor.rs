// Dev-only spawn-attribution baseline for bench.sh — NOT shipped, never on the
// hot path. The smallest possible Rust program (empty `main`), built with the
// same `[profile.release]` + static linking as the real binary. `bench.sh` times
// it between `/usr/bin/true` and the real binary so a run reads as three buckets:
//
//   /usr/bin/true            bare process spawn (execve + kernel page setup)
//   floor (this file)        + the full Rust std runtime init (lang_start, …)
//   claude-statusline        our real read + parse + render + write
//
// Because the real binary uses `#![no_main]` it SKIPS lang_start, so it can spawn
// in about the same time as `floor` — or less — despite doing real work. That gap
// is the concrete payoff of the `#![no_main]` change, made visible.
fn main() {}
