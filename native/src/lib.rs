// Core of the Claude Code status line: parse the JSON envelope, render the
// one-line output. Kept separate from `main.rs` so both the binary and the
// bench harness (`src/bin/bench.rs`) share exactly the same code.
//
// `render(input, now)` is pure (takes the clock as an argument) so it's
// deterministic and benchmarkable. No external deps: a small hand-written
// recursive-descent JSON parser (robust to whitespace/ordering/nesting).

// ── ANSI (must match statusline-command.sh exactly for byte-identical output) ─
const G: &str = "\x1b[92m"; // bright green — model bracket
const W: &str = "\x1b[97m"; // bright white
const D: &str = "\x1b[90m"; // dim grey — folder brackets / separators / ↻
const Y: &str = "\x1b[93m"; // yellow — cost
const C: &str = "\x1b[96m"; // cyan — duration
const R: &str = "\x1b[0m"; // reset
const DG: &str = "\x1b[32m"; // dim green — empty bar cells
const RED: &str = "\x1b[91m";
const YEL: &str = "\x1b[93m";
const GRN: &str = "\x1b[92m";
// 11-step green→red gradient (xterm-256 codes), indexed by pct/10.
const BAR_GRAD: [u16; 11] = [46, 82, 118, 154, 190, 226, 220, 214, 208, 202, 196];
const BAR_W: i64 = 5;

// ── Minimal JSON value + recursive-descent parser ──────────────────────────
// Some payloads (Null/Bool/Arr) are parsed only to advance correctly and are
// never read back — that's intentional, not dead code.
#[allow(dead_code)]
pub enum J {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<J>),
    Obj(Vec<(String, J)>),
}

impl J {
    fn get(&self, k: &str) -> Option<&J> {
        match self {
            J::Obj(m) => m.iter().find(|(kk, _)| kk == k).map(|(_, v)| v),
            _ => None,
        }
    }
    fn path(&self, ks: &[&str]) -> Option<&J> {
        let mut cur = self;
        for k in ks {
            cur = cur.get(k)?;
        }
        Some(cur)
    }
    fn as_str(&self) -> Option<&str> {
        match self {
            J::Str(s) => Some(s),
            _ => None,
        }
    }
    fn as_f64(&self) -> Option<f64> {
        match self {
            J::Num(n) => Some(*n),
            _ => None,
        }
    }
}

struct P<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> P<'a> {
    fn ws(&mut self) {
        while let Some(&c) = self.b.get(self.i) {
            if c == b' ' || c == b'\t' || c == b'\n' || c == b'\r' {
                self.i += 1;
            } else {
                break;
            }
        }
    }
    fn val(&mut self) -> Option<J> {
        self.ws();
        match *self.b.get(self.i)? {
            b'{' => self.obj(),
            b'[' => self.arr(),
            b'"' => Some(J::Str(self.string()?)),
            b't' => self.lit(b"true", J::Bool(true)),
            b'f' => self.lit(b"false", J::Bool(false)),
            b'n' => self.lit(b"null", J::Null),
            _ => self.number(),
        }
    }
    fn lit(&mut self, kw: &[u8], v: J) -> Option<J> {
        if self.b[self.i..].starts_with(kw) {
            self.i += kw.len();
            Some(v)
        } else {
            None
        }
    }
    fn number(&mut self) -> Option<J> {
        let start = self.i;
        while let Some(&c) = self.b.get(self.i) {
            if c == b'-' || c == b'+' || c == b'.' || c == b'e' || c == b'E' || c.is_ascii_digit() {
                self.i += 1;
            } else {
                break;
            }
        }
        std::str::from_utf8(&self.b[start..self.i])
            .ok()?
            .parse::<f64>()
            .ok()
            .map(J::Num)
    }
    fn string(&mut self) -> Option<String> {
        self.i += 1; // opening quote
        let mut s = String::new();
        loop {
            let c = *self.b.get(self.i)?;
            self.i += 1;
            match c {
                b'"' => return Some(s),
                b'\\' => {
                    let e = *self.b.get(self.i)?;
                    self.i += 1;
                    match e {
                        b'"' => s.push('"'),
                        b'\\' => s.push('\\'),
                        b'/' => s.push('/'),
                        b'n' => s.push('\n'),
                        b't' => s.push('\t'),
                        b'r' => s.push('\r'),
                        b'b' => s.push('\u{8}'),
                        b'f' => s.push('\u{c}'),
                        b'u' => {
                            let cp = self.hex4()?;
                            if (0xD800..=0xDBFF).contains(&cp) {
                                if self.b.get(self.i) == Some(&b'\\')
                                    && self.b.get(self.i + 1) == Some(&b'u')
                                {
                                    self.i += 2;
                                    let lo = self.hex4()?;
                                    let c = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                    s.push(char::from_u32(c).unwrap_or('\u{fffd}'));
                                } else {
                                    s.push('\u{fffd}');
                                }
                            } else {
                                s.push(char::from_u32(cp).unwrap_or('\u{fffd}'));
                            }
                        }
                        _ => return None,
                    }
                }
                _ => {
                    if c < 0x80 {
                        s.push(c as char);
                    } else {
                        let start = self.i - 1;
                        let len = if c >= 0xF0 {
                            4
                        } else if c >= 0xE0 {
                            3
                        } else {
                            2
                        };
                        self.i = start + len;
                        if let Ok(seg) = std::str::from_utf8(self.b.get(start..self.i)?) {
                            s.push_str(seg);
                        } else {
                            s.push('\u{fffd}');
                        }
                    }
                }
            }
        }
    }
    fn hex4(&mut self) -> Option<u32> {
        let h = self.b.get(self.i..self.i + 4)?;
        self.i += 4;
        u32::from_str_radix(std::str::from_utf8(h).ok()?, 16).ok()
    }
    fn arr(&mut self) -> Option<J> {
        self.i += 1; // [
        let mut v = Vec::new();
        self.ws();
        if self.b.get(self.i) == Some(&b']') {
            self.i += 1;
            return Some(J::Arr(v));
        }
        loop {
            v.push(self.val()?);
            self.ws();
            match self.b.get(self.i) {
                Some(&b',') => self.i += 1,
                Some(&b']') => {
                    self.i += 1;
                    return Some(J::Arr(v));
                }
                _ => return None,
            }
        }
    }
    fn obj(&mut self) -> Option<J> {
        self.i += 1; // {
        let mut m = Vec::new();
        self.ws();
        if self.b.get(self.i) == Some(&b'}') {
            self.i += 1;
            return Some(J::Obj(m));
        }
        loop {
            self.ws();
            if self.b.get(self.i) != Some(&b'"') {
                return None;
            }
            let k = self.string()?;
            self.ws();
            if self.b.get(self.i) != Some(&b':') {
                return None;
            }
            self.i += 1;
            let v = self.val()?;
            m.push((k, v));
            self.ws();
            match self.b.get(self.i) {
                Some(&b',') => self.i += 1,
                Some(&b'}') => {
                    self.i += 1;
                    return Some(J::Obj(m));
                }
                _ => return None,
            }
        }
    }
}

/// Parse a JSON document, returning `J::Null` on malformed input.
pub fn parse(b: &[u8]) -> J {
    P { b, i: 0 }.val().unwrap_or(J::Null)
}

// ── Rendering helpers ───────────────────────────────────────────────────────

// Integer value of a number field, truncated like bash's ${v%.*}.
fn int_at(root: &J, ks: &[&str]) -> Option<i64> {
    root.path(ks).and_then(|v| v.as_f64()).map(|f| f as i64)
}

fn pct_color(n: i64) -> &'static str {
    if n >= 80 {
        RED
    } else if n >= 50 {
        YEL
    } else {
        GRN
    }
}

pub fn render_bar(pct: i64, width: i64) -> String {
    let pct = pct.clamp(0, 100);
    let filled = ((pct * width + 50) / 100).min(width);
    let gi = (pct / 10).min(10) as usize;
    let mut s = format!("\x1b[38;5;{}m", BAR_GRAD[gi]);
    for _ in 0..filled {
        s.push('█');
    }
    s.push_str(DG);
    for _ in 0..(width - filled) {
        s.push('░');
    }
    s.push_str(&format!("{R} {W}{pct}%{R}"));
    s
}

/// Full pipeline: parse the envelope then render. `now` is the current unix
/// time in seconds (passed in so the function is pure and deterministic).
/// Output is byte-identical to statusline-command.sh for current envelopes.
pub fn render(input: &[u8], now: i64) -> String {
    render_parsed(&parse(input), now)
}

/// Render from an already-parsed tree — the formatting half of the pipeline,
/// split out so the bench can time parse vs. format separately.
pub fn render_parsed(root: &J, now: i64) -> String {
    let mut parts: Vec<String> = Vec::new();

    // Model + effort (effort sits right next to the model name).
    let model_full = root.path(&["model", "display_name"]).and_then(|v| v.as_str()).unwrap_or("");
    let model_short = if model_full.contains("Opus") {
        "Opus"
    } else if model_full.contains("Sonnet") {
        "Sonnet"
    } else if model_full.contains("Haiku") {
        "Haiku"
    } else {
        model_full.split(' ').next().filter(|s| !s.is_empty()).unwrap_or("?")
    };
    let effort = root.path(&["effort", "level"]).and_then(|v| v.as_str()).unwrap_or("");
    let effort_str = if !effort.is_empty() {
        let ec = match effort {
            "high" | "max" => RED,
            "medium" => YEL,
            _ => GRN,
        };
        format!(" {ec}{effort}{R}")
    } else {
        String::new()
    };
    parts.push(format!("{G}[{model_short}]{R}{effort_str}"));

    // Folder (current_dir → cwd → $PWD), basename, dim brackets.
    let dir = root
        .path(&["workspace", "current_dir"])
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from)
        .or_else(|| root.get("cwd").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from))
        .or_else(|| std::env::var("PWD").ok())
        .unwrap_or_default();
    let project = dir.rsplit('/').next().unwrap_or("");
    if !project.is_empty() {
        parts.push(format!("{D}[{R}{W}{project}{R}{D}]{R}"));
    }

    // Context bar.
    if let Some(ctx) = int_at(root, &["context_window", "used_percentage"]) {
        parts.push(format!("{W}ctx{R} {}", render_bar(ctx, BAR_W)));
    }

    // 5h bar + reset countdown.
    if let Some(p5) = int_at(root, &["rate_limits", "five_hour", "used_percentage"]) {
        let mut seg = format!("{W}5h{R} {}", render_bar(p5, BAR_W));
        if let Some(reset) = int_at(root, &["rate_limits", "five_hour", "resets_at"]) {
            let diff = reset - now;
            let r = if diff >= 3600 {
                format!("{}h{}m", diff / 3600, (diff % 3600) / 60)
            } else if diff >= 60 {
                format!("{}m", diff / 60)
            } else if diff > 0 {
                format!("{}s", diff)
            } else {
                String::new()
            };
            if !r.is_empty() {
                seg.push_str(&format!(" {D}↻{R}{W}{r}{R}"));
            }
        }
        parts.push(seg);
    }

    // Weekly: all-models (wk) and Sonnet-only (son, when a future envelope has it).
    if let Some(wk) = int_at(root, &["rate_limits", "seven_day", "used_percentage"]) {
        parts.push(format!("{W}wk{R} {}{wk}%{R}", pct_color(wk)));
    }
    if let Some(J::Obj(m)) = root.get("rate_limits") {
        for (k, v) in m {
            if k.to_ascii_lowercase().contains("sonnet") {
                if let Some(sp) = v.get("used_percentage").and_then(|x| x.as_f64()) {
                    let sp = sp as i64;
                    parts.push(format!("{W}son{R} {}{sp}%{R}", pct_color(sp)));
                }
                break;
            }
        }
    }

    // Duration (elapsed).
    if let Some(ms) = int_at(root, &["cost", "total_duration_ms"]) {
        let secs = ms / 1000;
        let dur = if secs >= 3600 {
            format!("{}h{}m", secs / 3600, (secs % 3600) / 60)
        } else if secs >= 60 {
            format!("{}m{}s", secs / 60, secs % 60)
        } else {
            format!("{}s", secs)
        };
        parts.push(format!("{C}{dur}{R}"));
    }

    // Cost (last column).
    if let Some(cost) = root.path(&["cost", "total_cost_usd"]).and_then(|v| v.as_f64()) {
        parts.push(format!("{Y}${cost:.2}{R}"));
    }

    parts.join(" ")
}

// ── Unit tests ──────────────────────────────────────────────────────────────
// Same-file child module: can reach private items (the `P` parser, the `J`
// accessors) as well as the public API. These cover the JSON parser, the bar,
// and the render helpers in isolation. The full exact-output battery and the
// cross-check against the bash script live in `tests/` (integration tests).
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard, OnceLock};

    // Tests that depend on the $PWD folder fallback mutate a process-global env
    // var; the test harness runs tests on parallel threads, so serialize every
    // PWD-sensitive test behind one lock. `set_pwd` sets $PWD and returns the
    // guard — hold it for the whole test so no other test changes $PWD meanwhile.
    fn env_lock() -> &'static Mutex<()> {
        static L: OnceLock<Mutex<()>> = OnceLock::new();
        L.get_or_init(|| Mutex::new(()))
    }
    fn set_pwd(dir: &str) -> MutexGuard<'static, ()> {
        let g = env_lock().lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("PWD", dir);
        g
    }

    // ---- small helpers for inspecting the parse tree -----------------------

    fn p(s: &str) -> J {
        parse(s.as_bytes())
    }

    fn is_null(j: &J) -> bool {
        matches!(j, J::Null)
    }

    // ---- JSON parser: primitives -------------------------------------------

    #[test]
    fn parse_true_false_null() {
        assert!(matches!(p("true"), J::Bool(true)));
        assert!(matches!(p("false"), J::Bool(false)));
        assert!(matches!(p("null"), J::Null));
        // Surrounding whitespace is tolerated.
        assert!(matches!(p("  \t\r\n true \n"), J::Bool(true)));
    }

    #[test]
    fn parse_integers_and_signs() {
        assert_eq!(p("0").as_f64(), Some(0.0));
        assert_eq!(p("42").as_f64(), Some(42.0));
        assert_eq!(p("-7").as_f64(), Some(-7.0));
        assert_eq!(p("123456789").as_f64(), Some(123456789.0));
    }

    #[test]
    fn parse_floats_and_exponents() {
        assert_eq!(p("1.25").as_f64(), Some(1.25));
        assert_eq!(p("-0.5").as_f64(), Some(-0.5));
        assert_eq!(p("1e3").as_f64(), Some(1000.0));
        assert_eq!(p("1E3").as_f64(), Some(1000.0));
        assert_eq!(p("2.5e-2").as_f64(), Some(0.025));
        assert_eq!(p("6.022e+23").as_f64(), Some(6.022e23));
        assert_eq!(p("42.9").as_f64(), Some(42.9));
    }

    #[test]
    fn parse_strings_basic_and_escapes() {
        assert_eq!(p(r#""hello""#).as_str(), Some("hello"));
        assert_eq!(p(r#""""#).as_str(), Some(""));
        // Two-char escapes.
        assert_eq!(p(r#""a\nb""#).as_str(), Some("a\nb"));
        assert_eq!(p(r#""a\tb""#).as_str(), Some("a\tb"));
        assert_eq!(p(r#""a\rb""#).as_str(), Some("a\rb"));
        assert_eq!(p(r#""q\"q""#).as_str(), Some("q\"q"));
        assert_eq!(p(r#""back\\slash""#).as_str(), Some("back\\slash"));
        assert_eq!(p(r#""a\/b""#).as_str(), Some("a/b"));
        assert_eq!(p(r#""\b\f""#).as_str(), Some("\u{8}\u{c}"));
    }

    #[test]
    fn parse_unicode_escapes() {
        // BMP escape (snowman).
        assert_eq!(p(r#""☃""#).as_str(), Some("\u{2603}"));
        // ASCII via \u.
        assert_eq!(p(r#""A""#).as_str(), Some("A"));
        // Surrogate pair → astral plane (😀 U+1F600).
        assert_eq!(p(r#""😀""#).as_str(), Some("😀"));
        // Lone high surrogate → replacement char.
        assert_eq!(p(r#""\uD83D""#).as_str(), Some("\u{fffd}"));
    }

    #[test]
    fn parse_raw_utf8_in_strings() {
        // Multi-byte UTF-8 bytes appear directly (not escaped).
        assert_eq!(p("\"café\"").as_str(), Some("café"));
        assert_eq!(p("\"日本語\"").as_str(), Some("日本語"));
        assert_eq!(p("\"😀\"").as_str(), Some("😀"));
    }

    // ---- JSON parser: containers -------------------------------------------

    #[test]
    fn parse_empty_containers() {
        assert!(matches!(p("{}"), J::Obj(ref m) if m.is_empty()));
        assert!(matches!(p("[]"), J::Arr(ref v) if v.is_empty()));
        assert!(matches!(p("  { }  "), J::Obj(ref m) if m.is_empty()));
        assert!(matches!(p(" [ ] "), J::Arr(ref v) if v.is_empty()));
    }

    #[test]
    fn parse_flat_object() {
        let j = p(r#"{"a": 1, "b": "two", "c": true, "d": null}"#);
        assert_eq!(j.get("a").and_then(J::as_f64), Some(1.0));
        assert_eq!(j.get("b").and_then(J::as_str), Some("two"));
        assert!(matches!(j.get("c"), Some(J::Bool(true))));
        assert!(matches!(j.get("d"), Some(J::Null)));
        assert!(j.get("missing").is_none());
    }

    #[test]
    fn parse_arrays_mixed() {
        let j = p(r#"[1, "x", true, null, [2, 3], {"k": 4}]"#);
        if let J::Arr(v) = &j {
            assert_eq!(v.len(), 6);
            assert_eq!(v[0].as_f64(), Some(1.0));
            assert_eq!(v[1].as_str(), Some("x"));
            assert!(matches!(v[2], J::Bool(true)));
            assert!(matches!(v[3], J::Null));
            assert!(matches!(v[4], J::Arr(_)));
            assert_eq!(v[5].get("k").and_then(J::as_f64), Some(4.0));
        } else {
            panic!("expected array");
        }
    }

    #[test]
    fn parse_deeply_nested() {
        let j = p(r#"{"a":{"b":{"c":{"d":[{"e":99}]}}}}"#);
        let inner = j.path(&["a", "b", "c", "d"]).unwrap();
        if let J::Arr(v) = inner {
            assert_eq!(v[0].get("e").and_then(J::as_f64), Some(99.0));
        } else {
            panic!("expected array at a.b.c.d");
        }
    }

    #[test]
    fn parse_whitespace_everywhere() {
        let j = p("{\n  \"a\" :\t1 ,\r\n  \"b\" : [ 1 , 2 ]\n}\n");
        assert_eq!(j.get("a").and_then(J::as_f64), Some(1.0));
        assert!(matches!(j.get("b"), Some(J::Arr(_))));
    }

    #[test]
    fn parse_path_and_get_on_nonobject() {
        let j = p("[1,2,3]");
        assert!(j.get("x").is_none());
        assert!(j.path(&["x"]).is_none());
        // path into a scalar bails out.
        assert!(p("5").path(&["a"]).is_none());
    }

    #[test]
    fn parse_realistic_envelope() {
        let j = p(r#"{"model":{"display_name":"Claude Opus 4.8"},"context_window":{"used_percentage":42.9},"cost":{"total_cost_usd":11.55}}"#);
        assert_eq!(
            j.path(&["model", "display_name"]).and_then(J::as_str),
            Some("Claude Opus 4.8")
        );
        assert_eq!(
            j.path(&["context_window", "used_percentage"]).and_then(J::as_f64),
            Some(42.9)
        );
    }

    // ---- JSON parser: malformed input must fail gracefully -----------------

    #[test]
    fn parse_malformed_returns_null_no_panic() {
        // Each of these is invalid JSON. `parse` must return J::Null, never panic.
        let bad = [
            "",                 // empty input
            "   ",              // whitespace only
            "{",                // unterminated object
            "}",                // stray close
            "[",                // unterminated array
            "[1,2",             // missing close bracket
            "[1,,2]",           // empty element
            "{\"a\":}",         // missing value
            "{\"a\" 1}",        // missing colon
            "{a:1}",            // unquoted key
            "{\"a\":1,}",       // trailing comma in object
            "\"unterminated",   // unterminated string
            "\"bad\\xescape\"", // invalid escape
            "tru",              // truncated literal
            "nul",              // truncated literal
            "fals",             // truncated literal
            "{\"a\":1 \"b\":2}", // missing comma
            "\"\\uZZZZ\"",      // non-hex unicode escape
            "\"\\u12\"",        // short unicode escape
            "@#$%",             // garbage
        ];
        for b in bad {
            assert!(is_null(&parse(b.as_bytes())), "expected Null for {b:?}");
        }
    }

    #[test]
    fn parse_huge_input_no_panic() {
        // Deeply nested arrays should not panic the recursive parser at a sane depth.
        let depth = 200;
        let s = "[".repeat(depth) + &"]".repeat(depth);
        let j = parse(s.as_bytes());
        assert!(matches!(j, J::Arr(_)));
    }

    // ---- render_bar --------------------------------------------------------

    #[test]
    fn bar_zero_pct() {
        // 0% → no filled cells, all empty, gradient index 0 (green 46).
        let s = render_bar(0, 5);
        assert_eq!(s, format!("\x1b[38;5;46m{DG}░░░░░{R} {W}0%{R}"));
    }

    #[test]
    fn bar_full_pct() {
        // 100% → all 5 filled, no empty, gradient index 10 (red 196).
        let s = render_bar(100, 5);
        assert_eq!(s, format!("\x1b[38;5;196m█████{DG}{R} {W}100%{R}"));
    }

    #[test]
    fn bar_half_pct() {
        // 50% of width 5 → round((50*5+50)/100)=3 filled cells; gradient idx 5 (226).
        let s = render_bar(50, 5);
        assert_eq!(s, format!("\x1b[38;5;226m███{DG}░░{R} {W}50%{R}"));
    }

    #[test]
    fn bar_overflow_clamped() {
        // >100 clamps to 100; gradient index never exceeds 10.
        assert_eq!(render_bar(150, 5), render_bar(100, 5));
        assert_eq!(render_bar(1000, 5), render_bar(100, 5));
        // Negative clamps to 0.
        assert_eq!(render_bar(-20, 5), render_bar(0, 5));
    }

    #[test]
    fn bar_filled_count_rounding() {
        // filled = (pct*width + 50)/100, capped at width. Check the rounding edges.
        fn filled(s: &str) -> usize {
            s.matches('█').count()
        }
        // width 5
        assert_eq!(filled(&render_bar(0, 5)), 0);
        assert_eq!(filled(&render_bar(9, 5)), 0); // (45+50)/100 = 0
        assert_eq!(filled(&render_bar(10, 5)), 1); // (50+50)/100 = 1
        assert_eq!(filled(&render_bar(30, 5)), 2); // (150+50)/100 = 2
        assert_eq!(filled(&render_bar(50, 5)), 3); // (250+50)/100 = 3
        assert_eq!(filled(&render_bar(90, 5)), 5); // (450+50)/100 = 5
        assert_eq!(filled(&render_bar(100, 5)), 5);
        // Empty count fills the remainder.
        assert_eq!(render_bar(30, 5).matches('░').count(), 3);
    }

    #[test]
    fn bar_custom_widths() {
        // width 10 at 50% → (50*10+50)/100 = 5 filled, 5 empty (integer division).
        let s = render_bar(50, 10);
        assert_eq!(s.matches('█').count(), 5);
        assert_eq!(s.matches('░').count(), 5);
        // width 10 at 55% → (550+50)/100 = 6 filled, 4 empty.
        let s55 = render_bar(55, 10);
        assert_eq!(s55.matches('█').count(), 6);
        assert_eq!(s55.matches('░').count(), 4);
        // width 1: 100% → 1 filled.
        assert_eq!(render_bar(100, 1).matches('█').count(), 1);
        assert_eq!(render_bar(0, 1).matches('░').count(), 1);
        // width 0: no cells either way.
        let z = render_bar(50, 0);
        assert_eq!(z.matches('█').count(), 0);
        assert_eq!(z.matches('░').count(), 0);
    }

    #[test]
    fn bar_gradient_color_boundaries() {
        // gi = (pct/10).min(10). Verify the color code at each decile boundary.
        fn color(pct: i64) -> String {
            let s = render_bar(pct, 5);
            // grab the leading "\x1b[38;5;NNNm"
            s.split('m').next().unwrap().to_string() + "m"
        }
        let grad = [46u16, 82, 118, 154, 190, 226, 220, 214, 208, 202, 196];
        for d in 0..=10i64 {
            let pct = (d * 10).min(100);
            assert_eq!(
                color(pct),
                format!("\x1b[38;5;{}m", grad[d as usize]),
                "decile {d} (pct {pct})"
            );
        }
        // 99% still in the last-but-... index 9 (gi = 9).
        assert_eq!(color(99), format!("\x1b[38;5;{}m", grad[9]));
        // Overflow gi capped at 10.
        assert_eq!(color(100), format!("\x1b[38;5;{}m", grad[10]));
    }

    // ---- pct_color / int_at internals --------------------------------------

    #[test]
    fn pct_color_thresholds() {
        assert_eq!(pct_color(0), GRN);
        assert_eq!(pct_color(49), GRN);
        assert_eq!(pct_color(50), YEL);
        assert_eq!(pct_color(79), YEL);
        assert_eq!(pct_color(80), RED);
        assert_eq!(pct_color(100), RED);
    }

    #[test]
    fn int_at_truncates_like_bash() {
        let j = p(r#"{"a":{"b":42.9}}"#);
        // truncation toward zero, mirroring bash ${v%.*}.
        assert_eq!(int_at(&j, &["a", "b"]), Some(42));
        assert_eq!(int_at(&j, &["a", "missing"]), None);
        let neg = p(r#"{"x":-3.9}"#);
        assert_eq!(int_at(&neg, &["x"]), Some(-3));
    }

    // ---- render: structural / guard behavior -------------------------------

    #[test]
    fn render_empty_object_is_model_and_folder_only() {
        // Set a deterministic PWD so the folder fallback is predictable.
        let _g = set_pwd("/x/proj");
        let out = render(b"{}", 1_700_000_000);
        // unknown model "?", folder from PWD basename, nothing else.
        assert_eq!(out, format!("{G}[?]{R} {D}[{R}{W}proj{R}{D}]{R}"));
    }

    #[test]
    fn render_malformed_input_does_not_panic() {
        // A malformed envelope parses to Null; render must still produce a line
        // (model "?", possibly a folder) and never panic.
        let _g = set_pwd("/x/proj");
        for bad in ["", "{", "not json", "[1,2,", "@@@@"] {
            let out = render(bad.as_bytes(), 1_700_000_000);
            assert!(out.contains("[?]"), "bad input {bad:?} -> {out:?}");
        }
    }

    #[test]
    fn render_malformed_numeric_fields_yield_no_segment() {
        // used_percentage as a string (not a number) → int_at returns None →
        // the ctx segment is simply omitted, no panic.
        let _g = set_pwd("/x/proj");
        let out = render(
            br#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":"oops"}}"#,
            1_700_000_000,
        );
        assert!(!out.contains("ctx"), "string pct should be skipped: {out:?}");
        // cost as a string → no cost segment.
        let out2 = render(
            br#"{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":"NaN"}}"#,
            1_700_000_000,
        );
        assert!(!out2.contains('$'), "string cost should be skipped: {out2:?}");
    }

    #[test]
    fn render_model_shortening() {
        let _g = set_pwd("/x/proj");
        let cases = [
            ("Claude Opus 4.8", "Opus"),
            ("Opus", "Opus"),
            ("Claude Sonnet 4.5", "Sonnet"),
            ("Claude Haiku 4.5", "Haiku"),
            ("GPT-Foo Bar", "GPT-Foo"), // unknown → first space-delimited token
            ("", "?"),                  // empty → ?
        ];
        for (full, short) in cases {
            let env = format!(r#"{{"model":{{"display_name":"{full}"}}}}"#);
            let out = render(env.as_bytes(), 1_700_000_000);
            assert!(
                out.starts_with(&format!("{G}[{short}]{R}")),
                "{full:?} -> {out:?} (expected short {short:?})"
            );
        }
    }

    #[test]
    fn render_effort_colors() {
        let _g = set_pwd("/x/proj");
        let cases = [
            ("high", RED),
            ("max", RED),
            ("medium", YEL),
            ("low", GRN),
            ("minimal", GRN),
        ];
        for (level, color) in cases {
            let env = format!(
                r#"{{"model":{{"display_name":"Opus"}},"effort":{{"level":"{level}"}}}}"#
            );
            let out = render(env.as_bytes(), 1_700_000_000);
            assert!(
                out.contains(&format!(" {color}{level}{R}")),
                "effort {level:?} color -> {out:?}"
            );
        }
        // No effort field → no effort segment between model and folder.
        let out = render(br#"{"model":{"display_name":"Opus"}}"#, 1_700_000_000);
        assert!(out.starts_with(&format!("{G}[Opus]{R} {D}[")), "{out:?}");
    }

    #[test]
    fn render_folder_precedence() {
        // current_dir wins over cwd wins over $PWD.
        let _g = set_pwd("/from/pwd");
        let both = render(
            br#"{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/a/cur"},"cwd":"/b/cwd"}"#,
            0,
        );
        assert!(both.contains(&format!("{W}cur{R}")), "{both:?}");
        let cwd_only = render(
            br#"{"model":{"display_name":"Opus"},"cwd":"/b/cwd"}"#,
            0,
        );
        assert!(cwd_only.contains(&format!("{W}cwd{R}")), "{cwd_only:?}");
        let pwd_only = render(br#"{"model":{"display_name":"Opus"}}"#, 0);
        assert!(pwd_only.contains(&format!("{W}pwd{R}")), "{pwd_only:?}");
    }

    #[test]
    fn render_reset_countdown_buckets() {
        // diff>=3600 → "XhYm"; >=60 → "Xm"; >0 → "Xs"; <=0 → omitted.
        let _g = set_pwd("/x/proj");
        let now = 1_700_000_000i64;
        let mk = |reset: i64| {
            format!(
                r#"{{"model":{{"display_name":"Opus"}},"rate_limits":{{"five_hour":{{"used_percentage":20,"resets_at":{reset}}}}}}}"#
            )
        };
        // 1h30m
        assert!(render(mk(now + 5400).as_bytes(), now).contains("↻"));
        assert!(render(mk(now + 5400).as_bytes(), now).contains("1h30m"));
        // 3m (>=60, <3600)
        assert!(render(mk(now + 200).as_bytes(), now).contains("3m"));
        // 30s
        assert!(render(mk(now + 30).as_bytes(), now).contains("30s"));
        // past → no countdown glyph at all (segment present but no ↻)
        let past = render(mk(now - 100).as_bytes(), now);
        assert!(!past.contains("↻"), "past reset should have no countdown: {past:?}");
        // still shows the 5h bar
        assert!(past.contains("5h"));
    }

    #[test]
    fn render_duration_buckets() {
        let _g = set_pwd("/x/proj");
        let mk = |ms: i64| {
            format!(r#"{{"model":{{"display_name":"Opus"}},"cost":{{"total_duration_ms":{ms}}}}}"#)
        };
        // 7s
        assert!(render(mk(7000).as_bytes(), 0).contains(&format!("{C}7s{R}")));
        // 2m3s (123s)
        assert!(render(mk(123000).as_bytes(), 0).contains(&format!("{C}2m3s{R}")));
        // 2h3m (7380s)
        assert!(render(mk(7380000).as_bytes(), 0).contains(&format!("{C}2h3m{R}")));
        // 0s
        assert!(render(mk(500).as_bytes(), 0).contains(&format!("{C}0s{R}")));
    }

    #[test]
    fn render_sonnet_weekly_bucket() {
        // A rate_limits key containing "sonnet" emits a `son` segment.
        let _g = set_pwd("/x/proj");
        let out = render(
            br#"{"model":{"display_name":"Opus"},"rate_limits":{"seven_day_sonnet":{"used_percentage":0}}}"#,
            0,
        );
        assert!(out.contains(&format!("{W}son{R}")), "{out:?}");
        assert!(out.contains(&format!("{GRN}0%{R}")), "{out:?}");
    }

    // ---- determinism -------------------------------------------------------

    #[test]
    fn render_is_deterministic() {
        let _g = set_pwd("/x/proj");
        let env = br#"{"model":{"display_name":"Claude Opus 4.8"},"workspace":{"current_dir":"/p/q"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":1.5,"total_duration_ms":61000},"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":9999999999},"seven_day":{"used_percentage":10}},"effort":{"level":"medium"}}"#;
        let now = 1_700_000_000;
        let a = render(env, now);
        let b = render(env, now);
        let c = render(env, now);
        assert_eq!(a, b);
        assert_eq!(b, c);
        // render == render_parsed(parse(..)) by construction.
        assert_eq!(render(env, now), render_parsed(&parse(env), now));
    }

    #[test]
    fn render_parsed_matches_render() {
        // Exercise parse + render_parsed directly and confirm equivalence to render.
        let _g = set_pwd("/x/proj");
        let envelopes: [&[u8]; 3] = [
            br#"{"model":{"display_name":"Sonnet"},"context_window":{"used_percentage":3}}"#,
            br#"{}"#,
            br#"{"model":{"display_name":"Opus"},"cost":{"total_cost_usd":0.08}}"#,
        ];
        for env in envelopes {
            let tree = parse(env);
            assert_eq!(render_parsed(&tree, 42), render(env, 42));
        }
    }
}
