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
    if let Some(ctx) = int_at(&root, &["context_window", "used_percentage"]) {
        parts.push(format!("{W}ctx{R} {}", render_bar(ctx, BAR_W)));
    }

    // 5h bar + reset countdown.
    if let Some(p5) = int_at(&root, &["rate_limits", "five_hour", "used_percentage"]) {
        let mut seg = format!("{W}5h{R} {}", render_bar(p5, BAR_W));
        if let Some(reset) = int_at(&root, &["rate_limits", "five_hour", "resets_at"]) {
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
    if let Some(wk) = int_at(&root, &["rate_limits", "seven_day", "used_percentage"]) {
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
    if let Some(ms) = int_at(&root, &["cost", "total_duration_ms"]) {
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
