// Thin entry point: read the JSON envelope from stdin, render, write the line.
// `#![no_main]` + a C `main` skips std's lang_start (stack-overflow guard install +
// SIGPIPE handler) — pure startup-syscall savings for a sub-millisecond process.
// Safe: the output line is < PIPE_BUF so the single write() to the pipe is atomic
// (no truncation), the result is ignored, and we exit immediately; default SIGPIPE
// is therefore harmless. All logic lives in lib.rs (shared with src/bin/bench.rs).
//
// Skipping lang_start also skips std's at-exit stdout flush, so we flush
// explicitly — the rendered line has no trailing newline and would otherwise
// stay in the line-buffered stdout and be lost.
#![no_main]
use claude_statusline::render;
use std::io::{self, Read, Write};
use std::time::{SystemTime, UNIX_EPOCH};

#[no_mangle]
pub extern "C" fn main(_argc: i32, _argv: *const *const u8) -> i32 {
    let mut input = Vec::new();
    let _ = io::stdin().read_to_end(&mut input);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let mut out = io::stdout().lock();
    let _ = out.write_all(render(&input, now).as_bytes());
    let _ = out.flush();
    0
}
