// Cross-check parity between the native binary and the bash script.
//
// `./parity-check.sh` (repo root) is the *canonical* cross-check: it diffs
// statusline-command.sh (with CLAUDE_STATUSLINE_THROTTLE=0) against the built
// binary across the 14-envelope battery and is run in CI / by the build scripts.
// This integration test mirrors that check from within `cargo test` so the
// parity guarantee is exercised by the Rust suite too.
//
// Both sides read the real wall clock at ~the same instant, so we keep every
// `resets_at` far in the future (stable "Xh Ym" bucket) to avoid clock-skew
// flakiness across the two process spawns. If `bash`, `jq`, or the script is
// unavailable, the test SKIPS (prints a note and returns) rather than failing —
// the suite must stay green on machines without the script's prerequisites.

use std::path::PathBuf;
use std::process::{Command, Stdio};

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR = <repo>/native ; parent is the repo root.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("native/ has a parent")
        .to_path_buf()
}

fn have(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Run `statusline-command.sh` with throttle disabled, feeding `input` on stdin.
fn run_script(root: &PathBuf, input: &str) -> Option<String> {
    let script = root.join("statusline-command.sh");
    if !script.exists() {
        return None;
    }
    let mut child = Command::new("bash")
        .arg(&script)
        .env("CLAUDE_STATUSLINE_THROTTLE", "0")
        .current_dir(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    use std::io::Write;
    child
        .stdin
        .take()?
        .write_all(input.as_bytes())
        .ok()?;
    let out = child.wait_with_output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The deterministic-bucket subset of the parity battery (resets far in the
/// future so the countdown text doesn't depend on the exact second).
fn battery() -> Vec<(&'static str, String)> {
    // Far-future absolute reset: keeps "Xh Ym" stable for both processes.
    let far = "9999999999";
    vec![
        (
            "full",
            format!(
                r#"{{"model":{{"display_name":"Claude Opus 4.8"}},"workspace":{{"current_dir":"/home/me/proj"}},"context_window":{{"used_percentage":42}},"cost":{{"total_cost_usd":11.55,"total_duration_ms":4560000}},"rate_limits":{{"five_hour":{{"used_percentage":85,"resets_at":{far}}},"seven_day":{{"used_percentage":10}}}},"effort":{{"level":"high"}}}}"#
            ),
        ),
        (
            "minimal",
            r#"{"model":{"display_name":"Sonnet"},"workspace":{"current_dir":"/p/q"},"context_window":{"used_percentage":3}}"#.to_string(),
        ),
        ("empty", r#"{"workspace":{"current_dir":"/p/q"}}"#.to_string()),
        (
            "no-effort",
            r#"{"model":{"display_name":"Claude Haiku 4.5"},"workspace":{"current_dir":"/a/b/c"},"context_window":{"used_percentage":50}}"#.to_string(),
        ),
        (
            "sonnet",
            format!(
                r#"{{"model":{{"display_name":"Opus"}},"workspace":{{"current_dir":"/p/q"}},"context_window":{{"used_percentage":7}},"rate_limits":{{"five_hour":{{"used_percentage":31,"resets_at":{far}}},"seven_day":{{"used_percentage":10}},"seven_day_sonnet":{{"used_percentage":0}}}}}}"#
            ),
        ),
        (
            "ctx0",
            r#"{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/p/q"},"context_window":{"used_percentage":0}}"#.to_string(),
        ),
        (
            "ctx100",
            r#"{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/p/q"},"context_window":{"used_percentage":100}}"#.to_string(),
        ),
        (
            "pct-float",
            r#"{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/p/q"},"context_window":{"used_percentage":42.9},"cost":{"total_cost_usd":0.08,"total_duration_ms":7000}}"#.to_string(),
        ),
        (
            "dur-hr",
            r#"{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/p/q"},"cost":{"total_duration_ms":7380000}}"#.to_string(),
        ),
        (
            "unknown-mdl",
            r#"{"model":{"display_name":"GPT-Foo Bar"},"workspace":{"current_dir":"/p/q"},"context_window":{"used_percentage":12}}"#.to_string(),
        ),
        (
            "nested-cw",
            format!(
                r#"{{"model":{{"display_name":"Opus"}},"workspace":{{"current_dir":"/p/q"}},"context_window":{{"current_usage":{{"input_tokens":5}},"used_percentage":63}},"rate_limits":{{"five_hour":{{"used_percentage":77,"resets_at":{far}}}}}}}"#
            ),
        ),
        (
            "no-model",
            r#"{"workspace":{"current_dir":"/p/q"},"context_window":{"used_percentage":5}}"#.to_string(),
        ),
    ]
}

#[test]
fn native_matches_bash_script() {
    let root = repo_root();
    let script = root.join("statusline-command.sh");

    // Skip gracefully if prerequisites are missing.
    if !script.exists() {
        eprintln!("SKIP parity: statusline-command.sh not found at {script:?}");
        return;
    }
    if !have("bash") {
        eprintln!("SKIP parity: `bash` not available");
        return;
    }
    if !have("jq") {
        eprintln!("SKIP parity: `jq` not available (the script needs it)");
        return;
    }
    // Smoke-test the script once; if it can't run here, skip rather than fail.
    if run_script(&root, r#"{"workspace":{"current_dir":"/p/q"}}"#).is_none() {
        eprintln!("SKIP parity: statusline-command.sh failed to run in this environment");
        return;
    }

    let mut checked = 0usize;
    for (label, input) in battery() {
        // Capture `now` around the script call so the native render uses the
        // same second; with far-future resets the countdown bucket is stable.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let script_out = run_script(&root, &input)
            .unwrap_or_else(|| panic!("script failed on case {label:?}"));
        let native_out = claude_statusline::render(input.as_bytes(), now);
        assert_eq!(
            native_out, script_out,
            "parity mismatch on case {label:?}\n native: {native_out:?}\n script: {script_out:?}"
        );
        checked += 1;
    }
    assert_eq!(checked, battery().len(), "expected to check every battery case");
    eprintln!("parity: native render matches bash script across {checked} envelopes");
}
