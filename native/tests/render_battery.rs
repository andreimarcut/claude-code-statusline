// Exact-output battery: assert the precise rendered string for the same 15
// envelopes that parity-check.sh diffs against the bash script. `now` is fixed
// (1_700_000_000) and every `resets_at` is built relative to it, so the
// countdown text is deterministic. Cases that omit a folder field fall back to
// $PWD, so we pin $PWD to a fixed value up front and run the whole battery in a
// single test (one process, no other test mutating env meanwhile).
//
// The expected strings were derived by running the real `render` and escaping
// the bytes — they are NOT hand-guessed escape codes. Anyone who changes the
// rendering must regenerate these (and statusline-command.sh + run parity-check).

use claude_statusline::render;

const NOW: i64 = 1_700_000_000;

/// Pin $PWD so the folder fallback (basename of $PWD) is deterministic, then
/// render. Every battery envelope that lacks a dir resolves to "myproj".
fn r(input: &str) -> String {
    std::env::set_var("PWD", "/work/myproj");
    render(input.as_bytes(), NOW)
}

#[test]
fn battery_exact_outputs() {
    // ---- full -----------------------------------------------------------
    assert_eq!(
        r(&format!(
            r#"{{"model":{{"display_name":"Claude Opus 4.8"}},"workspace":{{"current_dir":"/home/me/proj"}},"context_window":{{"used_percentage":42}},"cost":{{"total_cost_usd":11.55,"total_duration_ms":4560000}},"rate_limits":{{"five_hour":{{"used_percentage":85,"resets_at":{}}},"seven_day":{{"used_percentage":10}}}},"effort":{{"level":"high"}}}}"#,
            NOW + 5400
        )),
        "\x1b[92m[Opus]\x1b[0m \x1b[91mhigh\x1b[0m \x1b[90m[\x1b[0m\x1b[97mproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;190m██\x1b[32m░░░\x1b[0m \x1b[97m42%\x1b[0m \x1b[97m5h\x1b[0m \x1b[38;5;208m████\x1b[32m░\x1b[0m \x1b[97m85%\x1b[0m \x1b[90m↻\x1b[0m\x1b[97m1h30m\x1b[0m \x1b[97mwk\x1b[0m \x1b[92m10%\x1b[0m \x1b[90m·\x1b[0m \x1b[96m1h16m\x1b[0m \x1b[93m$11.55\x1b[0m",
        "full"
    );

    // ---- week-reset (days+hours) ----------------------------------------
    // 300000s = 3d (259200) + 40800s → 11h → "3d11h".
    assert_eq!(
        r(&format!(
            r#"{{"model":{{"display_name":"Opus"}},"rate_limits":{{"seven_day":{{"used_percentage":10,"resets_at":{}}}}}}}"#,
            NOW + 300000
        )),
        "\x1b[92m[Opus]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mwk\x1b[0m \x1b[92m10%\x1b[0m \x1b[90m↻\x1b[0m\x1b[97m3d11h\x1b[0m",
        "week-reset"
    );

    // ---- minimal --------------------------------------------------------
    assert_eq!(
        r(r#"{"model":{"display_name":"Sonnet"},"context_window":{"used_percentage":3}}"#),
        "\x1b[92m[Sonnet]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;46m\x1b[32m░░░░░\x1b[0m \x1b[97m3%\x1b[0m",
        "minimal"
    );

    // ---- empty ----------------------------------------------------------
    assert_eq!(
        r(r#"{}"#),
        "\x1b[92m[?]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m",
        "empty"
    );

    // ---- no-effort ------------------------------------------------------
    assert_eq!(
        r(r#"{"model":{"display_name":"Claude Haiku 4.5"},"workspace":{"current_dir":"/a/b/c"},"context_window":{"used_percentage":50}}"#),
        "\x1b[92m[Haiku]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mc\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;226m███\x1b[32m░░\x1b[0m \x1b[97m50%\x1b[0m",
        "no-effort"
    );

    // ---- sonnet ---------------------------------------------------------
    assert_eq!(
        r(&format!(
            r#"{{"model":{{"display_name":"Opus"}},"context_window":{{"used_percentage":7}},"rate_limits":{{"five_hour":{{"used_percentage":31,"resets_at":{}}},"seven_day":{{"used_percentage":10}},"seven_day_sonnet":{{"used_percentage":0}}}}}}"#,
            NOW + 200
        )),
        "\x1b[92m[Opus]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;46m\x1b[32m░░░░░\x1b[0m \x1b[97m7%\x1b[0m \x1b[97m5h\x1b[0m \x1b[38;5;154m██\x1b[32m░░░\x1b[0m \x1b[97m31%\x1b[0m \x1b[90m↻\x1b[0m\x1b[97m3m\x1b[0m \x1b[97mwk\x1b[0m \x1b[92m10%\x1b[0m \x1b[97mson\x1b[0m \x1b[92m0%\x1b[0m",
        "sonnet"
    );

    // ---- ctx0 -----------------------------------------------------------
    assert_eq!(
        r(r#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":0}}"#),
        "\x1b[92m[Opus]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;46m\x1b[32m░░░░░\x1b[0m \x1b[97m0%\x1b[0m",
        "ctx0"
    );

    // ---- ctx100 ---------------------------------------------------------
    assert_eq!(
        r(r#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":100}}"#),
        "\x1b[92m[Opus]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;196m█████\x1b[32m\x1b[0m \x1b[97m100%\x1b[0m",
        "ctx100"
    );

    // ---- pct-float ------------------------------------------------------
    assert_eq!(
        r(r#"{"model":{"display_name":"Opus"},"context_window":{"used_percentage":42.9},"cost":{"total_cost_usd":0.08,"total_duration_ms":7000}}"#),
        "\x1b[92m[Opus]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;190m██\x1b[32m░░░\x1b[0m \x1b[97m42%\x1b[0m \x1b[90m·\x1b[0m \x1b[96m7s\x1b[0m \x1b[93m$0.08\x1b[0m",
        "pct-float"
    );

    // ---- reset-past -----------------------------------------------------
    assert_eq!(
        r(&format!(
            r#"{{"model":{{"display_name":"Opus"}},"rate_limits":{{"five_hour":{{"used_percentage":20,"resets_at":{}}}}}}}"#,
            NOW - 100
        )),
        "\x1b[92m[Opus]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97m5h\x1b[0m \x1b[38;5;118m█\x1b[32m░░░░\x1b[0m \x1b[97m20%\x1b[0m",
        "reset-past"
    );

    // ---- reset-min ------------------------------------------------------
    assert_eq!(
        r(&format!(
            r#"{{"model":{{"display_name":"Opus"}},"rate_limits":{{"five_hour":{{"used_percentage":20,"resets_at":{}}}}}}}"#,
            NOW + 90
        )),
        "\x1b[92m[Opus]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97m5h\x1b[0m \x1b[38;5;118m█\x1b[32m░░░░\x1b[0m \x1b[97m20%\x1b[0m \x1b[90m↻\x1b[0m\x1b[97m1m\x1b[0m",
        "reset-min"
    );

    // ---- dur-hr ---------------------------------------------------------
    assert_eq!(
        r(r#"{"model":{"display_name":"Opus"},"cost":{"total_duration_ms":7380000}}"#),
        "\x1b[92m[Opus]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[96m2h3m\x1b[0m",
        "dur-hr"
    );

    // ---- unknown-mdl ----------------------------------------------------
    assert_eq!(
        r(r#"{"model":{"display_name":"GPT-Foo Bar"},"context_window":{"used_percentage":12}}"#),
        "\x1b[92m[GPT-Foo]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;82m█\x1b[32m░░░░\x1b[0m \x1b[97m12%\x1b[0m",
        "unknown-mdl"
    );

    // ---- nested-cw ------------------------------------------------------
    assert_eq!(
        r(&format!(
            r#"{{"model":{{"display_name":"Opus"}},"context_window":{{"current_usage":{{"input_tokens":5}},"used_percentage":63}},"rate_limits":{{"five_hour":{{"used_percentage":77,"resets_at":{}}}}}}}"#,
            NOW + 3700
        )),
        "\x1b[92m[Opus]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;220m███\x1b[32m░░\x1b[0m \x1b[97m63%\x1b[0m \x1b[97m5h\x1b[0m \x1b[38;5;214m████\x1b[32m░\x1b[0m \x1b[97m77%\x1b[0m \x1b[90m↻\x1b[0m\x1b[97m1h1m\x1b[0m",
        "nested-cw"
    );

    // ---- no-model -------------------------------------------------------
    assert_eq!(
        r(r#"{"context_window":{"used_percentage":5}}"#),
        "\x1b[92m[?]\x1b[0m \x1b[90m[\x1b[0m\x1b[97mmyproj\x1b[0m\x1b[90m]\x1b[0m \x1b[97mctx\x1b[0m \x1b[38;5;46m\x1b[32m░░░░░\x1b[0m \x1b[97m5%\x1b[0m",
        "no-model"
    );
}
