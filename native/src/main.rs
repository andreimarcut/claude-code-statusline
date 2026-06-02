// Thin entry point: read the JSON envelope from stdin, render, write the line.
// All logic lives in lib.rs (shared with the bench harness in src/bin/bench.rs).
use claude_statusline::render;
use std::io::{self, Read, Write};
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let mut input = Vec::new();
    let _ = io::stdin().read_to_end(&mut input);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let _ = io::stdout().write_all(render(&input, now).as_bytes());
}
