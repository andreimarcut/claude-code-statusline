// Micro-benchmark for the in-process work — separate from the `claude-statusline`
// binary (this is its own `bench` bin). It times the logic only (parse, format,
// the bar); process startup + dynamic linking (the ~0.7ms that dominates a real
// invocation) is OS overhead measured externally by ../../bench.sh.
//
// Run:  cargo run --release --bin bench
//
// Zero deps, stable Rust: warmup, std::hint::black_box to defeat dead-code
// elimination, many iters across several batches, report ns/op (min + mean).

use claude_statusline::{parse, render, render_parsed, render_bar};
use std::hint::black_box;
use std::time::Instant;

// A realistic envelope (resets_at far in the future so the countdown path runs).
const SAMPLE: &[u8] = br#"{"model":{"display_name":"Claude Opus 4.8"},"session_id":"bench","workspace":{"current_dir":"/home/me/projects/demo"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":5,"output_tokens":2}},"cost":{"total_cost_usd":11.55,"total_duration_ms":4560000},"rate_limits":{"five_hour":{"used_percentage":85,"resets_at":4102444800},"seven_day":{"used_percentage":10}},"effort":{"level":"high"}}"#;
const NOW: i64 = 1_780_000_000;

fn bench<T>(name: &str, iters: u64, batches: u32, mut f: impl FnMut() -> T) {
    for _ in 0..(iters / 10).max(1000) {
        black_box(f());
    }
    let (mut min, mut sum) = (f64::INFINITY, 0.0);
    for _ in 0..batches {
        let t = Instant::now();
        for _ in 0..iters {
            black_box(f());
        }
        let ns = t.elapsed().as_nanos() as f64 / iters as f64;
        min = min.min(ns);
        sum += ns;
    }
    println!("  {name:<22} {min:>8.1} ns/op (min)   {:>8.1} ns/op (mean)", sum / batches as f64);
}

fn main() {
    let iters = 1_000_000;
    let batches = 8;
    println!("claude-statusline in-process micro-bench ({iters} iters × {batches} batches)");
    println!("  sample out: {}", render(SAMPLE, NOW));
    println!("  (logic only — process spawn + dynamic linking is measured by bench.sh)\n");

    // Pre-parse once so the format-only bench doesn't re-parse.
    let tree = parse(SAMPLE);

    bench("parse JSON", iters, batches, || parse(black_box(SAMPLE)));
    bench("render_parsed (format)", iters, batches, || render_parsed(black_box(&tree), NOW));
    bench("render (parse+format)", iters, batches, || render(black_box(SAMPLE), NOW));
    bench("render_bar (one bar)", iters, batches, || render_bar(black_box(42), 5));
}
