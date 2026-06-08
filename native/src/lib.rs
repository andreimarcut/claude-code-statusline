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

/// The default layout, as a template string (see the template engine below).
/// Fed through `render_template` it reproduces `render_parsed`'s output for a
/// full envelope byte-for-byte. `install.sh` writes this into the settings.json
/// `env` block so the layout is visible and user-editable; when the env var is
/// unset/empty OR equals this constant, the fast hardcoded path runs instead.
/// MUST stay byte-identical to `DEFAULT_TEMPLATE` in statusline-command.sh.
pub const DEFAULT_TEMPLATE: &str = "{bright_green}[{json.model.display_name:short}]{reset}{json.effort.level:effort} {grey}[{reset}{bright_white}{json.workspace.current_dir:folder}{reset}{grey}]{reset}{^}{?json.context_window.used_percentage} {bright_white}ctx{reset} {json.context_window.used_percentage:bar}{/}{?json.rate_limits.five_hour.used_percentage} {bright_white}5h{reset} {json.rate_limits.five_hour.used_percentage:bar}{json.rate_limits.five_hour.resets_at:countdown}{/}{?json.rate_limits.seven_day.used_percentage} {bright_white}wk{reset} {json.rate_limits.seven_day.used_percentage:pct}{json.rate_limits.seven_day.resets_at:countdown}{/}{?json.rate_limits.__sonnet__.used_percentage} {bright_white}son{reset} {json.rate_limits.__sonnet__.used_percentage:pct}{/} {sep} {json.cost.total_duration_ms:dur} {json.cost.total_cost_usd:usd}";

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

/// Uniform duration formatting, used for every time field (uptime + both
/// reset countdowns): the two largest units down to the hour ("4d3h",
/// "5h12m"), then a single unit below ("30m", "45s"). Non-positive → empty.
fn fmt_dur(s: i64) -> String {
    if s >= 86400 {
        format!("{}d{}h", s / 86400, (s % 86400) / 3600)
    } else if s >= 3600 {
        format!("{}h{}m", s / 3600, (s % 3600) / 60)
    } else if s >= 60 {
        format!("{}m", s / 60)
    } else if s >= 0 {
        format!("{}s", s)
    } else {
        String::new()
    }
}

// Like fmt_dur, but keeps seconds at the minute scale ("18m35s" where fmt_dur
// gives "18m"); day/hour scales drop seconds the same way fmt_dur does.
fn fmt_dur_secs(s: i64) -> String {
    if s >= 86400 {
        format!("{}d{}h", s / 86400, (s % 86400) / 3600)
    } else if s >= 3600 {
        format!("{}h{}m", s / 3600, (s % 3600) / 60)
    } else if s >= 60 {
        format!("{}m{}s", s / 60, s % 60)
    } else if s >= 0 {
        format!("{}s", s)
    } else {
        String::new()
    }
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

// Shorten a model display name to Opus/Sonnet/Haiku, else its first word, else "?".
fn model_short(full: &str) -> &str {
    if full.contains("Opus") {
        "Opus"
    } else if full.contains("Sonnet") {
        "Sonnet"
    } else if full.contains("Haiku") {
        "Haiku"
    } else {
        full.split(' ').next().filter(|s| !s.is_empty()).unwrap_or("?")
    }
}

// Model family + trailing version: "Claude Opus 4.8" -> "Opus-4.8". The version
// is the first whitespace-delimited token that is all digits and dots; with none,
// the family alone is returned (same fallback as model_short). Split on the same
// chars as bash's default IFS (space/tab/newline) so the version search stays
// byte-identical to the script's `read -ra` arm.
fn family_version(full: &str) -> String {
    let family = model_short(full);
    match full.split([' ', '\t', '\n']).find(|t| {
        t.chars().next().map_or(false, |c| c.is_ascii_digit())
            && t.chars().all(|c| c.is_ascii_digit() || c == '.')
    }) {
        Some(version) => format!("{family}-{version}"),
        None => family.to_string(),
    }
}

// Context-window size from the token count in `context_window.context_window_size`
// (authoritative; Claude Code pre-computes 200000 / 1000000): "1m" at >=1M tokens,
// else "Nk" (200000 -> "200k"). Absent/non-numeric is handled by the caller, which
// falls back to the documented 200k default.
fn ctx_size(n: i64) -> String {
    if n >= 1_000_000 {
        "1m".to_string()
    } else {
        format!("{}k", n / 1000)
    }
}

// Effort level → SGR color (high/max red, medium yellow, else green).
fn effort_color(level: &str) -> &'static str {
    match level {
        "high" | "max" => RED,
        "medium" => YEL,
        _ => GRN,
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
///
/// Layout source: the `CLAUDE_STATUSLINE_TEMPLATE` template env var. When it is
/// unset/empty OR equals `DEFAULT_TEMPLATE`, the fast hardcoded `render_parsed`
/// path runs (zero engine cost); otherwise the template engine renders it.
/// `render_parsed`/`render_template` stay pure (env is read only here) so tests
/// drive them directly.
pub fn render(input: &[u8], now: i64) -> String {
    match std::env::var("CLAUDE_STATUSLINE_TEMPLATE") {
        Ok(t) if !t.is_empty() && t != DEFAULT_TEMPLATE => render_template(&parse(input), now, &t),
        _ => render_parsed(&parse(input), now),
    }
}

/// Render from an already-parsed tree — the formatting half of the pipeline,
/// split out so the bench can time parse vs. format separately.
pub fn render_parsed(root: &J, now: i64) -> String {
    let mut parts: Vec<String> = Vec::new();

    // Model + effort (effort sits right next to the model name).
    let model_full = root.path(&["model", "display_name"]).and_then(|v| v.as_str()).unwrap_or("");
    let model_short = model_short(model_full);
    let effort = root.path(&["effort", "level"]).and_then(|v| v.as_str()).unwrap_or("");
    let effort_str = if !effort.is_empty() {
        format!(" {}{effort}{R}", effort_color(effort))
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

    // Mark: any ctx/quota segment lands past here. Used to decide whether the
    // trailing timing/cost group needs a bullet separator before it.
    let group_base = parts.len();

    // Context bar.
    if let Some(ctx) = int_at(root, &["context_window", "used_percentage"]) {
        parts.push(format!("{W}ctx{R} {}", render_bar(ctx, BAR_W)));
    }

    // 5h bar + reset countdown.
    if let Some(p5) = int_at(root, &["rate_limits", "five_hour", "used_percentage"]) {
        let mut seg = format!("{W}5h{R} {}", render_bar(p5, BAR_W));
        if let Some(reset) = int_at(root, &["rate_limits", "five_hour", "resets_at"]) {
            let diff = reset - now;
            let r = if diff > 0 { fmt_dur(diff) } else { String::new() };
            if !r.is_empty() {
                seg.push_str(&format!(" {D}↻{R}{W}{r}{R}"));
            }
        }
        parts.push(seg);
    }

    // Weekly: all-models (wk) and Sonnet-only (son, when a future envelope has it).
    if let Some(wk) = int_at(root, &["rate_limits", "seven_day", "used_percentage"]) {
        let mut seg = format!("{W}wk{R} {}{wk}%{R}", pct_color(wk));
        // Reset countdown — same uniform format as everywhere else.
        if let Some(reset) = int_at(root, &["rate_limits", "seven_day", "resets_at"]) {
            let diff = reset - now;
            let r = if diff > 0 { fmt_dur(diff) } else { String::new() };
            if !r.is_empty() {
                seg.push_str(&format!(" {D}↻{R}{W}{r}{R}"));
            }
        }
        parts.push(seg);
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

    // Duration (elapsed) and cost form the trailing timing/cost group; set
    // it off from the quotas with a bullet separator.
    let dur = int_at(root, &["cost", "total_duration_ms"]).map(|ms| fmt_dur(ms / 1000));
    // Cost via the same integer-cents round2 the template engine uses, so the
    // hardcoded path and the engine (and bash) all agree on half-cent values.
    let cost = root
        .path(&["cost", "total_cost_usd"])
        .filter(|v| matches!(v, J::Num(_)))
        .map(|v| round2(&node_text(v)));
    if parts.len() > group_base && (dur.is_some() || cost.is_some()) {
        parts.push(format!("{D}·{R}"));
    }
    if let Some(dur) = dur {
        parts.push(format!("{C}{dur}{R}"));
    }
    if let Some(cost) = cost {
        parts.push(format!("{Y}${cost}{R}"));
    }

    parts.join(" ")
}

// ── Template engine (opt-in via CLAUDE_STATUSLINE_TEMPLATE) ────────────────────
// A template string lays out the line. Tokens:
//   {json.a.b.c}        value at that envelope path, raw text
//   {json.a.b.c:fmt}    value rendered by a named format (bar/pct/dur/…)
//   {sep} / {sep:type}  smart separator (shown only when flanked by content)
//   {colorname}         ANSI SGR (named/bright/bg/256/rgb/hex/style); zero-width
// Everything else (text, raw ANSI, unicode, newline→row) passes through.
// Empty fields auto-collapse one adjacent space; see `emit`.

// Item class for separator/collapse logic.
#[derive(PartialEq)]
enum Cls {
    Vis,     // visible content (non-empty value, non-space literal, shown sep)
    Gap,     // a run of spaces/tabs (collapsible separator)
    Zero,    // zero-width bytes (color tokens) — emitted, transparent to spacing
    Empty,   // empty field / suppressed sep — emits nothing, transparent
    Newline, // hard line break (new status row)
    Sep,     // unresolved smart separator
    Bound,   // invisible boundary: a smart sep won't scan across it
}
struct Item {
    text: String,
    cls: Cls,
}

// Resolve a dotted path, honoring the synthetic `rate_limits.__sonnet__`
// segment (any rate_limits key containing "sonnet", case-insensitive).
fn tpl_resolve<'a>(root: &'a J, path: &[String]) -> Option<&'a J> {
    if path.len() >= 2 && path[0] == "rate_limits" && path[1] == "__sonnet__" {
        if let Some(J::Obj(m)) = root.get("rate_limits") {
            for (k, v) in m {
                if k.to_ascii_lowercase().contains("sonnet") {
                    let segs: Vec<&str> = path[2..].iter().map(String::as_str).collect();
                    return v.path(&segs);
                }
            }
        }
        return None;
    }
    let segs: Vec<&str> = path.iter().map(|s| s.as_str()).collect();
    root.path(&segs)
}

// jq-`tostring`-ish text for a raw scalar (null/absent → empty, like bash `// ""`).
fn node_text(n: &J) -> String {
    match n {
        // Strip any embedded 0x1f: the bash engine reserves it as its field
        // terminator and gsubs it out, so we must too for byte-identical output.
        J::Str(s) => s.replace('\u{1f}', ""),
        J::Bool(b) => b.to_string(),
        J::Num(x) => {
            // Mirrors the bash jq canonicalization in _render_template: a whole
            // value below 9e15 renders as a plain integer (so 42.0/5e1 → 42/50);
            // anything else falls back to the language's default number format.
            // NOTE bounded contract: above 9e15 Rust's `{}` (expanded decimal)
            // and jq's `tostring` (exponent) diverge — not reachable for real
            // envelope fields (percentages, ms, cost, token counts).
            if *x == x.trunc() && x.abs() < 9e15 {
                format!("{}", *x as i64)
            } else {
                format!("{}", x)
            }
        }
        _ => String::new(),
    }
}

// Render one `{json.path:fmt}` to its string (empty if absent/not applicable).
// Does the canonical text look numeric to bash's `[[ =~ ^-?[0-9]+(\.[0-9]+)?$ ]]`?
fn is_numeric_text(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    if i < b.len() && b[i] == b'-' {
        i += 1;
    }
    let int_start = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    // Need ≥1 integer digit, and cap at 15 so the value stays within i64 and
    // f64-exact range — mirrors the bash regex `^-?[0-9]{1,15}(\.[0-9]+)?$`, so
    // an absurd magnitude renders empty in BOTH engines (no bash arithmetic
    // error, no divergence) rather than overflowing. Real fields are far smaller.
    let int_digits = i - int_start;
    if int_digits == 0 || int_digits > 15 {
        return false;
    }
    if i < b.len() && b[i] == b'.' {
        i += 1;
        let frac_start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == frac_start {
            return false; // a '.' must be followed by digits
        }
    }
    i == b.len()
}

// Integer part of numeric text, mirroring bash `${v%.*}` (truncate toward zero).
fn int_part(s: &str) -> i64 {
    s.split('.').next().unwrap_or("").parse::<i64>().unwrap_or(0)
}

// Format numeric text as dollars.cents, rounding half-up on the DECIMAL TEXT
// (not the f64) — locale- and float-formatter-independent, so it's byte-identical
// to bash `_round2`. (Neither bash `printf %.2f` nor Rust `{:.2}` would agree
// across engines on half-cent values; this integer-cents path does.)
// Input is is_numeric_text-validated, so int_v fits i64.
fn round2(s: &str) -> String {
    let (sign, body) = match s.strip_prefix('-') {
        Some(b) => ("-", b),
        None => ("", s),
    };
    let (int, frac) = body.split_once('.').unwrap_or((body, ""));
    let mut fp = frac.to_string();
    fp.push_str("000"); // ensure ≥3 fractional digits to read the rounding digit
    let d2: i64 = fp[0..2].parse().unwrap_or(0);
    let round_up = fp.as_bytes()[2] >= b'5';
    let mut cents = int.parse::<i64>().unwrap_or(0) * 100 + d2;
    if round_up {
        cents += 1;
    }
    format!("{sign}{}.{:02}", cents / 100, cents % 100)
}

// Render one {json.path:fmt} value. Operates on the field's CANONICAL TEXT
// (node_text — the exact string the bash engine's jq step produces for that
// field), then dispatches identically to statusline-command.sh's _fmt_field, so
// the two engines render byte-for-byte the same for every field type.
fn fmt_value(root: &J, path: &[String], fmt: Option<&str>, now: i64) -> String {
    let text = tpl_resolve(root, path).map(node_text).unwrap_or_default();
    let numeric = is_numeric_text(&text);
    match fmt.unwrap_or("text") {
        "short" => model_short(&text).to_string(),
        // Family + trailing version ("Opus-4.8"); no version -> family alone.
        "familyver" => family_version(&text),
        // Context-window size from context_window.context_window_size: "1m" / "Nk".
        // Absent/non-numeric falls back to the documented 200k default.
        "ctxsize" => if numeric { ctx_size(int_part(&text)) } else { "200k".to_string() },
        // Pure last-path-component; empty → empty (no workspace fallback).
        "basename" => text.rsplit('/').next().unwrap_or("").to_string(),
        // The current folder: value → cwd → $PWD, then basename (matches the
        // hardcoded folder segment's fallback chain).
        "folder" => {
            let v = if !text.is_empty() {
                text.clone()
            } else {
                root.get("cwd")
                    .and_then(|n| n.as_str())
                    .filter(|s| !s.is_empty())
                    .map(String::from)
                    .or_else(|| std::env::var("PWD").ok())
                    .unwrap_or_default()
            };
            v.rsplit('/').next().unwrap_or("").to_string()
        }
        "effort" => {
            if text.is_empty() {
                String::new()
            } else {
                format!(" {}{text}{R}", effort_color(&text))
            }
        }
        "bar" => {
            if numeric {
                render_bar(int_part(&text), BAR_W)
            } else {
                String::new()
            }
        }
        "pct" => {
            if numeric {
                let n = int_part(&text);
                format!("{}{n}%{R}", pct_color(n))
            } else {
                String::new()
            }
        }
        "pct-plain" => {
            if numeric {
                format!("{}%", int_part(&text))
            } else {
                String::new()
            }
        }
        "dur" => {
            if numeric {
                let d = fmt_dur(int_part(&text) / 1000);
                if d.is_empty() {
                    String::new()
                } else {
                    format!("{C}{d}{R}")
                }
            } else {
                String::new()
            }
        }
        "dur-secs" => {
            if numeric {
                let d = fmt_dur_secs(int_part(&text) / 1000);
                if d.is_empty() {
                    String::new()
                } else {
                    format!("{C}{d}{R}")
                }
            } else {
                String::new()
            }
        }
        "usd" => {
            if numeric {
                format!("{Y}${}{R}", round2(&text))
            } else {
                String::new()
            }
        }
        "countdown" => {
            if numeric {
                let diff = int_part(&text) - now;
                let d = if diff > 0 { fmt_dur(diff) } else { String::new() };
                if d.is_empty() {
                    String::new()
                } else {
                    format!(" {D}↻{R}{W}{d}{R}")
                }
            } else {
                String::new()
            }
        }
        // "text" and any unknown format → the raw canonical text.
        _ => text,
    }
}

// Is `{json.path}` present and non-empty? Drives conditional groups `{?path}…{/}`.
fn field_present(root: &J, path: &[String]) -> bool {
    tpl_resolve(root, path).map(|n| !node_text(n).is_empty()).unwrap_or(false)
}

// Separator glyph for `{sep[:type]}` (dim-grey, except `space`).
fn sep_glyph(kind: &str) -> String {
    match kind {
        "space" => " ".to_string(),
        "pipe" => format!("{D}|{R}"),
        "dot" => format!("{D}•{R}"),
        "slash" => format!("{D}/{R}"),
        _ => format!("{D}·{R}"), // bullet (default)
    }
}

// Named/extended color token → SGR escape. None if unrecognized.
fn color_token(name: &str) -> Option<String> {
    let simple = |c: &str| Some(format!("\x1b[{c}m"));
    match name {
        "reset" => return simple("0"),
        "bold" => return simple("1"),
        "dim" => return simple("2"),
        "italic" => return simple("3"),
        "underline" => return simple("4"),
        "blink" => return simple("5"),
        "reverse" => return simple("7"),
        "hidden" => return simple("8"),
        "strike" => return simple("9"),
        _ => {}
    }
    // foreground base code for a named/bright color.
    fn fg(name: &str) -> Option<u16> {
        Some(match name {
            "black" => 30,
            "red" => 31,
            "green" => 32,
            "yellow" => 33,
            "blue" => 34,
            "magenta" => 35,
            "cyan" => 36,
            "white" => 37,
            "bright_black" | "grey" | "gray" => 90,
            "bright_red" => 91,
            "bright_green" => 92,
            "bright_yellow" => 93,
            "bright_blue" => 94,
            "bright_magenta" => 95,
            "bright_cyan" => 96,
            "bright_white" => 97,
            _ => return None,
        })
    }
    if let Some(c) = fg(name) {
        return simple(&c.to_string());
    }
    if let Some(rest) = name.strip_prefix("bg_") {
        // background = fg code + 10 (40-47 / 100-107).
        return fg(rest).map(|c| format!("\x1b[{}m", c + 10));
    }
    if let Some(n) = name.strip_prefix("fg256:").and_then(|s| s.parse::<u16>().ok()) {
        if n <= 255 {
            return simple(&format!("38;5;{n}"));
        }
    }
    if let Some(n) = name.strip_prefix("bg256:").and_then(|s| s.parse::<u16>().ok()) {
        if n <= 255 {
            return simple(&format!("48;5;{n}"));
        }
    }
    let rgb = |s: &str| -> Option<(u16, u16, u16)> {
        let p: Vec<_> = s.split(',').collect();
        if p.len() == 3 {
            let r = p[0].trim().parse::<u16>().ok()?;
            let g = p[1].trim().parse::<u16>().ok()?;
            let b = p[2].trim().parse::<u16>().ok()?;
            if r <= 255 && g <= 255 && b <= 255 {
                return Some((r, g, b));
            }
        }
        None
    };
    if let Some(s) = name.strip_prefix("rgb:") {
        if let Some((r, g, b)) = rgb(s) {
            return simple(&format!("38;2;{r};{g};{b}"));
        }
    }
    if let Some(s) = name.strip_prefix("bgrgb:") {
        if let Some((r, g, b)) = rgb(s) {
            return simple(&format!("48;2;{r};{g};{b}"));
        }
    }
    let hex = |s: &str| -> Option<(u16, u16, u16)> {
        let h = s.strip_prefix('#')?;
        if h.len() == 6 {
            let r = u16::from_str_radix(&h[0..2], 16).ok()?;
            let g = u16::from_str_radix(&h[2..4], 16).ok()?;
            let b = u16::from_str_radix(&h[4..6], 16).ok()?;
            return Some((r, g, b));
        }
        None
    };
    if name.starts_with('#') {
        if let Some((r, g, b)) = hex(name) {
            return simple(&format!("38;2;{r};{g};{b}"));
        }
    }
    if let Some(s) = name.strip_prefix("bg") {
        if s.starts_with('#') {
            if let Some((r, g, b)) = hex(s) {
                return simple(&format!("48;2;{r};{g};{b}"));
            }
        }
    }
    None
}

// Interpret backslash escapes within a literal run (real control bytes from
// JSON `` already pass through untouched).
fn unescape_into(out: &mut String, chars: &[char], i: &mut usize) {
    // caller guarantees chars[*i] == '\\' and there is a next char
    let n = chars[*i + 1];
    match n {
        'e' => {
            out.push('\u{1b}');
            *i += 2;
        }
        'n' => {
            out.push('\n');
            *i += 2;
        }
        't' => {
            out.push('\t');
            *i += 2;
        }
        '\\' => {
            out.push('\\');
            *i += 2;
        }
        '{' => {
            out.push('{');
            *i += 2;
        }
        '}' => {
            out.push('}');
            *i += 2;
        }
        'x' => {
            let h: String = chars.get(*i + 2..*i + 4).map(|s| s.iter().collect()).unwrap_or_default();
            if h.len() == 2 {
                if let Ok(b) = u32::from_str_radix(&h, 16) {
                    if let Some(c) = char::from_u32(b) {
                        out.push(c);
                    }
                    *i += 4;
                    return;
                }
            }
            out.push('\\');
            *i += 1;
        }
        'u' => {
            let h: String = chars.get(*i + 2..*i + 6).map(|s| s.iter().collect()).unwrap_or_default();
            if h.len() == 4 {
                if let Ok(cp) = u32::from_str_radix(&h, 16) {
                    if let Some(c) = char::from_u32(cp) {
                        out.push(c);
                    }
                    *i += 6;
                    return;
                }
            }
            out.push('\\');
            *i += 1;
        }
        '0'..='7' => {
            // up to 3 octal digits (\033 → ESC)
            let mut j = *i + 1;
            let mut val: u32 = 0;
            let mut cnt = 0;
            while j < chars.len() && cnt < 3 && ('0'..='7').contains(&chars[j]) {
                val = val * 8 + (chars[j] as u32 - '0' as u32);
                j += 1;
                cnt += 1;
            }
            if let Some(c) = char::from_u32(val) {
                out.push(c);
            }
            *i = j;
        }
        _ => {
            out.push('\\');
            *i += 1;
        }
    }
}

// Split an (already-unescaped) literal run into Vis / Gap / Newline items.
fn flush_lit(lit: &mut String, items: &mut Vec<Item>) {
    if lit.is_empty() {
        return;
    }
    let mut cur = String::new();
    let mut ws = false; // current run is whitespace
    for ch in lit.chars() {
        if ch == '\n' {
            if !cur.is_empty() {
                items.push(Item { text: std::mem::take(&mut cur), cls: if ws { Cls::Gap } else { Cls::Vis } });
            }
            items.push(Item { text: String::new(), cls: Cls::Newline });
            ws = false;
        } else if ch == ' ' || ch == '\t' {
            if !ws && !cur.is_empty() {
                items.push(Item { text: std::mem::take(&mut cur), cls: Cls::Vis });
            }
            ws = true;
            cur.push(ch);
        } else {
            if ws && !cur.is_empty() {
                items.push(Item { text: std::mem::take(&mut cur), cls: Cls::Gap });
            }
            ws = false;
            cur.push(ch);
        }
    }
    if !cur.is_empty() {
        items.push(Item { text: cur, cls: if ws { Cls::Gap } else { Cls::Vis } });
    }
    lit.clear();
}

fn classify_placeholder(inner: &str, root: &J, now: i64, items: &mut Vec<Item>) {
    if inner == "^" {
        items.push(Item { text: String::new(), cls: Cls::Bound });
        return;
    }
    if inner == "sep" || inner.starts_with("sep:") {
        let kind = inner.strip_prefix("sep:").unwrap_or("bullet");
        items.push(Item { text: sep_glyph(kind), cls: Cls::Sep });
        return;
    }
    if let Some(stripped) = inner.strip_prefix("json.") {
        let (pathpart, fmt) = match stripped.split_once(':') {
            Some((p, f)) => (p, Some(f)),
            None => (stripped, None),
        };
        let path: Vec<String> = pathpart.split('.').map(String::from).collect();
        let text = fmt_value(root, &path, fmt, now);
        items.push(Item { cls: if text.is_empty() { Cls::Empty } else { Cls::Vis }, text });
        return;
    }
    if let Some(sgr) = color_token(inner) {
        items.push(Item { text: sgr, cls: Cls::Zero });
        return;
    }
    // Unknown placeholder → show literally (typos stay visible).
    items.push(Item { text: format!("{{{inner}}}"), cls: Cls::Vis });
}

// A smart `{sep}` is kept only when flanked by visible content on both sides
// (scanning past transparent Gap/Zero/Empty; another Sep or a Newline blocks).
fn has_vis(items: &[Item], idx: usize, forward: bool) -> bool {
    // Scan outward (mirrors bash `_eng_has_vis`): the nearest Vis means "flanked",
    // a Sep/Newline/Bound blocks, everything else is transparent.
    let found = |j: usize| match items[j].cls {
        Cls::Vis => Some(true),
        Cls::Sep | Cls::Newline | Cls::Bound => Some(false),
        _ => None,
    };
    if forward {
        (idx + 1..items.len()).find_map(found)
    } else {
        (0..idx).rev().find_map(found)
    }
    .unwrap_or(false)
}

fn emit(items: &[Item]) -> String {
    let mut out = String::new();
    let mut pending = false; // a held gap awaiting the next visible/zero
    let mut vis = false; // emitted any visible content on this line
    for it in items {
        match it.cls {
            Cls::Newline => {
                out.push('\n');
                pending = false;
                vis = false;
            }
            Cls::Gap => {
                if vis {
                    pending = true;
                }
            }
            Cls::Empty | Cls::Bound => {} // transparent
            Cls::Zero => {
                if pending {
                    out.push(' ');
                    pending = false;
                }
                out.push_str(&it.text);
            }
            Cls::Vis | Cls::Sep => {
                if pending {
                    out.push(' ');
                    pending = false;
                }
                out.push_str(&it.text);
                vis = true;
            }
        }
    }
    out
}

/// Render an envelope through a template string. Pure (`now` and env-derived
/// `tpl` are passed in).
pub fn render_template(root: &J, now: i64, tpl: &str) -> String {
    let chars: Vec<char> = tpl.chars().collect();
    let mut items: Vec<Item> = Vec::new();
    let mut lit = String::new();
    // Conditional-group stack: `{?json.path}` pushes the field's presence, `{/}`
    // pops. Content is emitted only while every frame is true.
    let mut frames: Vec<bool> = Vec::new();
    let active = |f: &[bool]| f.iter().all(|&b| b);
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '\\' && i + 1 < chars.len() {
            if active(&frames) {
                unescape_into(&mut lit, &chars, &mut i);
            } else {
                i += 2; // skip the escape pair while in a hidden group
            }
            continue;
        }
        if c == '{' {
            if let Some(end) = chars[i + 1..].iter().position(|&x| x == '}') {
                let inner: String = chars[i + 1..i + 1 + end].iter().collect();
                i = i + 1 + end + 1;
                if inner == "/" {
                    if active(&frames) {
                        flush_lit(&mut lit, &mut items);
                    } else {
                        lit.clear();
                    }
                    frames.pop();
                    continue;
                }
                if let Some(cond) = inner.strip_prefix('?') {
                    if active(&frames) {
                        flush_lit(&mut lit, &mut items);
                    } else {
                        lit.clear();
                    }
                    let pp = cond.strip_prefix("json.").unwrap_or(cond);
                    let path: Vec<String> = pp.split('.').map(String::from).collect();
                    frames.push(field_present(root, &path));
                    continue;
                }
                if active(&frames) {
                    flush_lit(&mut lit, &mut items);
                    classify_placeholder(&inner, root, now, &mut items);
                } else {
                    lit.clear();
                }
                continue;
            }
        }
        if active(&frames) {
            lit.push(c);
        }
        i += 1;
    }
    flush_lit(&mut lit, &mut items);

    // Resolve smart separators (left→right; a suppressed sep becomes transparent).
    for idx in 0..items.len() {
        if items[idx].cls == Cls::Sep && !(has_vis(&items, idx, false) && has_vis(&items, idx, true)) {
            items[idx].text.clear();
            items[idx].cls = Cls::Empty;
        }
    }
    emit(&items)
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
        // 2m (123s → minutes alone, uniform format)
        assert!(render(mk(123000).as_bytes(), 0).contains(&format!("{C}2m{R}")));
        // 2h3m (7380s)
        assert!(render(mk(7380000).as_bytes(), 0).contains(&format!("{C}2h3m{R}")));
        // 1d1h (90000s → days+hours)
        assert!(render(mk(90000000).as_bytes(), 0).contains(&format!("{C}1d1h{R}")));
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
