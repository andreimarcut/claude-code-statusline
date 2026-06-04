// Template-engine tests. Two halves:
//  1. `default_template_matches_hardcoded` — the DEFAULT_TEMPLATE fed through the
//     engine must equal the hardcoded `render_parsed` output, byte-for-byte, for
//     every parity envelope. This is the core faithfulness guarantee (the
//     install-written default reproduces today's look exactly).
//  2. exact-output cases for custom templates: formats, color tokens, smart
//     separators, auto-collapse, conditional groups, multi-line, raw paths,
//     malformed input. `now` is fixed; `$PWD` pinned for the folder fallback.

use claude_statusline::{parse, render_parsed, render_template, DEFAULT_TEMPLATE};

const NOW: i64 = 1_700_000_000;

fn pin() {
    std::env::set_var("PWD", "/work/myproj");
}
fn eng(env: &str, tpl: &str) -> String {
    pin();
    render_template(&parse(env.as_bytes()), NOW, tpl)
}
fn hard(env: &str) -> String {
    pin();
    render_parsed(&parse(env.as_bytes()), NOW)
}

#[test]
fn default_template_matches_hardcoded() {
    let envs: Vec<String> = vec![
        format!(
            r#"{{"model":{{"display_name":"Claude Opus 4.8"}},"workspace":{{"current_dir":"/home/me/proj"}},"context_window":{{"used_percentage":42}},"cost":{{"total_cost_usd":11.55,"total_duration_ms":4560000}},"rate_limits":{{"five_hour":{{"used_percentage":85,"resets_at":{}}},"seven_day":{{"used_percentage":10}}}},"effort":{{"level":"high"}}}}"#,
            NOW + 5400
        ),
        format!(
            r#"{{"model":{{"display_name":"Opus"}},"rate_limits":{{"seven_day":{{"used_percentage":10,"resets_at":{}}}}}}}"#,
            NOW + 300000
        ),
        r#"{"model":{"display_name":"Sonnet"},"context_window":{"used_percentage":3}}"#.into(),
        r#"{}"#.into(),
        r#"{"model":{"display_name":"Claude Haiku 4.5"},"workspace":{"current_dir":"/a/b/c"},"context_window":{"used_percentage":50}}"#.into(),
        format!(
            r#"{{"model":{{"display_name":"Opus"}},"context_window":{{"used_percentage":7}},"rate_limits":{{"five_hour":{{"used_percentage":31,"resets_at":{}}},"seven_day":{{"used_percentage":10}},"seven_day_sonnet":{{"used_percentage":0}}}}}}"#,
            NOW + 200
        ),
        r#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":0}}"#.into(),
        r#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":100}}"#.into(),
        r#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.9},"cost":{"total_cost_usd":0.08,"total_duration_ms":7000}}"#.into(),
        format!(
            r#"{{"model":{{"display_name":"Opus"}},"rate_limits":{{"five_hour":{{"used_percentage":20,"resets_at":{}}}}}}}"#,
            NOW - 100
        ),
        format!(
            r#"{{"model":{{"display_name":"Opus"}},"rate_limits":{{"five_hour":{{"used_percentage":20,"resets_at":{}}}}}}}"#,
            NOW + 90
        ),
        r#"{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":7380000}}"#.into(),
        r#"{"model":{"display_name":"GPT-Foo Bar"},"context_window":{"used_percentage":12}}"#.into(),
        format!(
            r#"{{"model":{{"display_name":"Opus"}},"context_window":{{"current_usage":{{"input_tokens":5}},"used_percentage":63}},"rate_limits":{{"five_hour":{{"used_percentage":77,"resets_at":{}}}}}}}"#,
            NOW + 3700
        ),
        r#"{"context_window":{"used_percentage":5}}"#.into(),
    ];
    for env in &envs {
        assert_eq!(eng(env, DEFAULT_TEMPLATE), hard(env), "default template != hardcoded for env: {env}");
    }
}

#[test]
fn custom_templates() {
    let opus = r#"{"model":{"display_name":"Claude Opus 4.8"},"effort":{"level":"high"},"cost":{"total_cost_usd":1.5,"total_duration_ms":65000},"context_window":{"used_percentage":42}}"#;

    // Minimal: short model + usd, single space literal.
    assert_eq!(eng(opus, "{json.model.display_name:short} {json.cost.total_cost_usd:usd}"), "Opus \x1b[93m$1.50\x1b[0m");

    // Color tokens (named + bright) wrap raw text; reset closes.
    assert_eq!(eng(opus, "{red}{json.effort.level}{reset}"), "\x1b[31mhigh\x1b[0m");
    assert_eq!(eng(opus, "{bright_green}x{reset}"), "\x1b[92mx\x1b[0m");

    // Extended colors: 256, rgb, hex, bg, style.
    assert_eq!(eng(opus, "{fg256:208}o{reset}"), "\x1b[38;5;208mo\x1b[0m");
    assert_eq!(eng(opus, "{rgb:10,20,30}o{reset}"), "\x1b[38;2;10;20;30mo\x1b[0m");
    assert_eq!(eng(opus, "{#ff8800}o{reset}"), "\x1b[38;2;255;136;0mo\x1b[0m");
    assert_eq!(eng(opus, "{bg_blue}o{reset}"), "\x1b[44mo\x1b[0m");
    assert_eq!(eng(opus, "{bold}o{reset}"), "\x1b[1mo\x1b[0m");

    // Background variants: bg256, bgrgb, bg#hex.
    assert_eq!(eng(opus, "{bg256:200}o{reset}"), "\x1b[48;5;200mo\x1b[0m");
    assert_eq!(eng(opus, "{bgrgb:10,20,30}o{reset}"), "\x1b[48;2;10;20;30mo\x1b[0m");
    assert_eq!(eng(opus, "{bg#ff0080}o{reset}"), "\x1b[48;2;255;0;128mo\x1b[0m");

    // Duration uses the minutes-alone bucket (65000ms -> 1m), cyan-wrapped.
    assert_eq!(eng(opus, "{json.cost.total_duration_ms:dur}"), "\x1b[96m1m\x1b[0m");

    // pct (colored) vs pct-plain (no color); 42% with green severity.
    assert_eq!(eng(opus, "{json.context_window.used_percentage:pct}"), "\x1b[92m42%\x1b[0m");
    assert_eq!(eng(opus, "{json.context_window.used_percentage:pct-plain}"), "42%");

    // Smart separator shows only when flanked by content on BOTH sides.
    assert_eq!(eng(opus, "a {sep} b"), "a \x1b[90m·\x1b[0m b");
    assert_eq!(eng(opus, "a {sep} {json.nope.field}"), "a"); // right side empty -> sep + trailing space dropped
    assert_eq!(eng(opus, "{json.nope.field} {sep} b"), "b"); // left side empty -> sep dropped
    assert_eq!(eng(opus, "a {sep:pipe} b"), "a \x1b[90m|\x1b[0m b");
    // The remaining sep glyph variants: dot (•), slash (/), space (plain).
    assert_eq!(eng(opus, "a {sep:dot} b"), "a \x1b[90m\u{2022}\x1b[0m b");
    assert_eq!(eng(opus, "a {sep:slash} b"), "a \x1b[90m/\x1b[0m b");
    assert_eq!(eng(opus, "a{sep:space}b"), "a b");
    assert_eq!(eng(opus, "{json.nope.field}{sep:space}b"), "b"); // empty side suppresses

    // Auto-collapse: an empty field between spaces does not leave a double space.
    assert_eq!(eng(opus, "a {json.nope.field} b"), "a b");
    assert_eq!(eng(opus, "{json.nope.x}a"), "a"); // leading empty, no leading space

    // Conditional group: hidden when the field is absent, shown when present.
    assert_eq!(eng(opus, "x{?json.nope.field} ctx {json.context_window.used_percentage:bar}{/} y"), "x y");
    assert_eq!(eng(opus, "x{?json.context_window.used_percentage} ok{/} y"), "x ok y");

    // Multi-line: a literal \n becomes a row break; each row trimmed/collapsed.
    assert_eq!(eng(opus, "{json.model.display_name:short}\\n{json.effort.level}"), "Opus\nhigh");

    // Raw path access to a non-default field (proves arbitrary {json.path}).
    let lines = r#"{"cost":{"total_lines_added":156,"total_lines_removed":23}}"#;
    assert_eq!(eng(lines, "+{json.cost.total_lines_added}/-{json.cost.total_lines_removed}"), "+156/-23");

    // :basename is a pure last-component (empty in → empty, no workspace leak);
    // :folder carries the value→cwd→$PWD fallback (pinned PWD = /work/myproj).
    assert_eq!(eng(r#"{"workspace":{"current_dir":"/a/b/proj"}}"#, "{json.workspace.current_dir:basename}"), "proj");
    assert_eq!(eng("{}", "{json.nope.path:basename}"), "");
    assert_eq!(eng("{}", "{json.nope.path:folder}"), "myproj");
    assert_eq!(eng(r#"{"cwd":"/x/y/zed"}"#, "{json.workspace.current_dir:folder}"), "zed");

    // Escapes: \e and \033 both yield ESC; \t and \uXXXX interpreted.
    assert_eq!(eng(opus, "\\e[1mX\\e[0m"), "\x1b[1mX\x1b[0m");
    assert_eq!(eng(opus, "\\033[1mX\\033[0m"), "\x1b[1mX\x1b[0m");
    // \t is interpreted, but a tab is whitespace so flush_lit collapses it to a
    // single inter-word gap (same as a space) — matching the bash engine.
    assert_eq!(eng(opus, "x\\ty"), "x y");
    assert_eq!(eng(opus, "\\u2665"), "\u{2665}"); // ♥
    // \xHH and \NNN name a Unicode codepoint emitted as UTF-8 (matches bash);
    // a lone surrogate from \uXXXX is dropped (char::from_u32 -> None).
    assert_eq!(eng(opus, "\\xC3"), "\u{00C3}");
    assert_eq!(eng(opus, "\\303"), "\u{00C3}");
    assert_eq!(eng(opus, "[\\uD83D]"), "[]");

    // Boolean false renders as "false" (jq `//` would drop it; we use a
    // null-only fallback) and makes a {?path} group present.
    let bools = r#"{"x":{"y":false}}"#;
    assert_eq!(eng(bools, "A{?json.x.y}B{json.x.y}C{/}D"), "ABfalseCD");

    // {?path} resolves with the `json.` prefix optional, against the root.
    assert_eq!(eng(r#"{"foo":"bar"}"#, "{?foo}FOUND{/}"), "FOUND");

    // A field value containing a newline is preserved intact (no column shift).
    assert_eq!(eng(r#"{"a":"foo\nbar","b":"X"}"#, "A={json.a} B={json.b}"), "A=foo\nbar B=X");

    // :countdown standalone — NOW+5400 (1h30m) renders, NOW (==now) suppresses.
    let cd_env = format!(r#"{{"r":{{"resets_at":{}}}}}"#, NOW + 5400);
    assert_eq!(eng(&cd_env, "{json.r.resets_at:countdown}"), " \x1b[90m\u{21bb}\x1b[0m\x1b[97m1h30m\x1b[0m");
    let cd_now = format!(r#"{{"r":{{"resets_at":{NOW}}}}}"#);
    assert_eq!(eng(&cd_now, "[{json.r.resets_at:countdown}]"), "[]");

    // Containers (array/object) are empty: {json.path} text is "" and {?path} is
    // absent — byte-identical to the bash engine (jq filter emits "" for them).
    assert_eq!(eng(r#"{"x":[1,2]}"#, "[{json.x}]"), "[]");
    assert_eq!(eng(r#"{"x":{}}"#, "{?json.x}YES{/}NO"), "NO");
    // A section path is an object → treated as absent in BOTH engines (not "HAS").
    assert_eq!(eng(r#"{"rate_limits":{"five_hour":{"used_percentage":20}}}"#, "{?json.rate_limits}HAS{/}NO"), "NO");

    // Whole-valued / exponent numbers normalize to integer form (node_text), so
    // `42.0`→`42`, `5e1`→`50`; bash's jq canonicalizer matches.
    assert_eq!(eng(r#"{"x":42.0}"#, "[{json.x}]"), "[42]");
    assert_eq!(eng(r#"{"x":5e1}"#, "{json.x:pct-plain} [{json.x}]"), "50% [50]");

    // Negative numerics render in both engines (as_f64 + relaxed bash regex).
    assert_eq!(eng(r#"{"x":-5}"#, "{json.x:pct-plain}"), "-5%");
    assert_eq!(eng(r#"{"c":{"total_cost_usd":-3.5}}"#, "{json.c.total_cost_usd:usd}"), "\x1b[93m$-3.50\x1b[0m");

    // Empty path / bare cond: empty value / absent group (no panic; matches bash).
    assert_eq!(eng("{}", "A{json.}B"), "AB");
    assert_eq!(eng("{}", "A{?}B{/}C"), "AC");

    // /code-review regression fixes:
    // F1 — a path indexing THROUGH a scalar yields "" for just that field (not a
    // whole-line blank), so the folder still renders.
    assert_eq!(
        eng(r#"{"model":{"display_name":"Sonnet"},"workspace":{"current_dir":"/t/proj"}}"#, "[{json.model.display_name.x}] [{json.workspace.current_dir:basename}]"),
        "[] [proj]"
    );
    // F2 — an out-of-i64-range numeric (>15 integer digits) → empty, no overflow.
    assert_eq!(eng(r#"{"x":9500000000000000000}"#, "{json.x:bar}"), "");
    assert_eq!(eng(r#"{"x":1234567890123}"#, "{json.x:pct-plain}"), "1234567890123%");
    // F4 — cost is integer-cents round-HALF-UP (deterministic, locale-free), incl. carry.
    assert_eq!(eng(r#"{"c":{"total_cost_usd":11.555}}"#, "{json.c.total_cost_usd:usd}"), "\x1b[93m$11.56\x1b[0m");
    assert_eq!(eng(r#"{"c":{"total_cost_usd":0.005}}"#, "{json.c.total_cost_usd:usd}"), "\x1b[93m$0.01\x1b[0m");
    assert_eq!(eng(r#"{"c":{"total_cost_usd":9.995}}"#, "{json.c.total_cost_usd:usd}"), "\x1b[93m$10.00\x1b[0m");
    assert_eq!(eng(r#"{"c":{"total_cost_usd":2.675}}"#, "{json.c.total_cost_usd:usd}"), "\x1b[93m$2.68\x1b[0m");
}

#[test]
fn malformed_templates_never_panic() {
    let env = r#"{"model":{"display_name":"Opus"}}"#;
    // Unterminated placeholder, unknown format, unknown color, unknown path,
    // stray group close — none may panic; output is best-effort.
    for tpl in [
        "{json.model.display_name", // no closing brace
        "{json.model.display_name:zzz}",
        "{octarine}x{reset}",
        "{json.does.not.exist}",
        "{/}{/}{/}",
        "{?json.nope}{json.model.display_name:short}", // group never closed
        "",
    ] {
        let _ = eng(env, tpl); // must return without panicking
    }
}
