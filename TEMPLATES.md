# Customizing the status line with a template

The status line's layout is a **template string**. You set it once and both the
bash script and the native binary render it identically. Order, visibility,
separators, per-field format, colors, and even multiple rows all come from this
one string.

> **Just ask Claude.** Open this repo (or your settings) in Claude Code and say
> *"hide cost and move ctx last"*, *"show the git branch"*, *"make the model name
> magenta"*. Claude edits the template for you — see [Agentic self-service](#agentic-self-service).

## Where the template lives

The status line only receives the session JSON on stdin — it is **not** handed
your `settings.json`. So the template travels in the settings.json top-level
**`env` block**, which Claude Code injects into the command's environment (this
works for the native binary too, with no shell wrapper):

```jsonc
{
  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh", "refreshInterval": 60 },
  "env": {
    "CLAUDE_STATUSLINE_FIELDS": "{bright_green}[{json.model.display_name:short}]{reset} …",
    "CLAUDE_STATUSLINE_THROTTLE": "2",
    "CLAUDE_STATUSLINE_CTX_MAX": "1000000"
  }
}
```

`install.sh` writes the **default** template here so you can see and edit it.

- **Unset or empty** → the built-in default layout renders (byte-identical, fastest path).
- **Set to the default string** → same fast path (an exact-match short-circuit; no engine cost).
- **Anything else** → the template engine renders your layout.

Changes take effect on the **next status-line refresh** — no restart, no daemon.

`CLAUDE_STATUSLINE_THROTTLE` (seconds; default `2`, `0` disables) and
`CLAUDE_STATUSLINE_CTX_MAX` (context-window size for the older transcript
fallback; default `1000000`) live in the same `env` block.

## Syntax

| Token | Meaning |
|---|---|
| `{json.a.b.c}` | Value at that envelope path, as text (scalars only — an array/object path is treated as empty). Any field works — see [Fields](#field-reference). |
| `{json.a.b.c:format}` | Value rendered by a named **format** (bar, pct, dur, …). |
| `{sep}` / `{sep:type}` | **Smart separator** — shown only when there's visible content on both sides. |
| `{^}` | Invisible **boundary** — a smart separator won't scan across it (groups segments). |
| `{?json.a.b.c}` … `{/}` | **Conditional group** — render the enclosed part only if that field is present. |
| `{color}` | An ANSI color/style (see [Colors](#color-tokens)). Zero-width. |
| anything else | Literal text — emitted as-is (unicode, raw ANSI, etc.). |
| `\n` | Newline → a second status **row** (Claude Code renders each line as a row). |

Backslash escapes inside literals are interpreted: `\e`, `\033`, `\x1b` → ESC;
`\n` → newline; `\t` → tab; `\uXXXX` → unicode; `\{`, `\}`, `\\` → literal.
(In JSON you can also just write `` for ESC and `\n` for a newline.)

## Formats

A format is the part after `:` in `{json.path:format}`. It picks how the value is
rendered, including any value-dependent color (a bar's gradient, a percent's
green/yellow/red threshold).

| Format | For | Renders |
|---|---|---|
| `bar` | a percentage (0–100) | gradient bar + `NN%` (like `ctx`/`5h`) |
| `pct` | a percentage | `NN%` colored by severity (green<50, yellow<80, red≥80) |
| `pct-plain` | a percentage | `NN%`, no color |
| `dur` | milliseconds | elapsed time `4d3h`/`5h12m`/`30m`/`45s`, cyan |
| `countdown` | a unix timestamp | ` ↻4d3h` until that time, or empty if past |
| `usd` | a number | `$N.NN`, yellow |
| `short` | `model.display_name` | `Opus`/`Sonnet`/`Haiku`/first word/`?` |
| `basename` | a path | last path component (empty in → empty out) |
| `folder` | `workspace.current_dir` | the current folder: value→`cwd`→`$PWD`, then basename |
| `effort` | `effort.level` | ` level` colored by level (leading space included) |
| `text` *(default)* | anything | the raw value |

A field that's absent (or whose value doesn't fit the format, e.g. `:bar` on a
non-number) renders **empty**, and an empty field auto-collapses (see below).

## Color tokens

`{name}` emits an ANSI escape and counts as zero-width (so it never trips the
smart separator). Raw escapes like `\e[38;5;208m` work too.

- **Named (8):** `black red green yellow blue magenta cyan white`
- **Bright (8):** `bright_black` (alias `grey`/`gray`) `bright_red … bright_white`
- **Backgrounds:** prefix any of the above with `bg_` (`bg_red`, `bg_bright_blue`)
- **256-color:** `{fg256:N}` / `{bg256:N}` where `N` is 0–255
- **Truecolor:** `{rgb:R,G,B}` / `{bgrgb:R,G,B}` and hex `{#RRGGBB}` / `{bg#RRGGBB}`
- **Styles:** `bold dim italic underline blink reverse hidden strike`
- **`reset`** clears all attributes

## Smart separators & auto-collapse

These two rules let a flat template behave like the conditional default layout:

- **`{sep}` shows only when flanked by visible content on both sides.** So
  `wk 10% {sep} 1h16m` shows the bullet, but if the cost/duration is absent the
  bullet disappears with it. Types: `{sep}`/`{sep:bullet}` → `·`, `{sep:pipe}` →
  `|`, `{sep:dot}` → `•`, `{sep:slash}` → `/`, `{sep:space}` → a plain space.
  A `{^}` boundary or a newline stops the scan (so a separator never reaches
  across into the model/folder header, for instance).
- **An empty field collapses one adjacent space**, so `a {json.missing} b` →
  `a b`, not `a  b`. Runs of spaces render as a single space.

For a label that should disappear *with* its value, wrap it in a conditional
group: `{?json.rate_limits.five_hour.used_percentage} {bright_white}5h{reset} {json.rate_limits.five_hour.used_percentage:bar}{/}`.

## Field reference

The default layout reads these (all from the
[status line JSON input](https://code.claude.com/docs/en/statusline#available-data)):

- `model.display_name` — model name (`:short` → Opus/Sonnet/Haiku)
- `effort.level` — reasoning effort (`:effort`)
- `workspace.current_dir` — current folder (`:folder`)
- `context_window.used_percentage` — context bar (`:bar`)
- `rate_limits.five_hour.used_percentage` / `.resets_at` — 5h bar + countdown
- `rate_limits.seven_day.used_percentage` / `.resets_at` — weekly (all-models) + countdown
- `rate_limits.__sonnet__.used_percentage` — Sonnet-only weekly (synthetic: matches any
  `rate_limits` key containing "sonnet"; surfaces automatically if Claude Code adds it)
- `cost.total_duration_ms` — elapsed time (`:dur`)
- `cost.total_cost_usd` — session cost (`:usd`)

**Any** other documented field is reachable with `{json.<path>}` — e.g.
`{json.cost.total_lines_added}`, `{json.workspace.repo.name}`, `{json.pr.number}`,
`{json.session_name}`, `{json.version}`, `{json.vim.mode}`. See the full list and
exact paths in the [Claude Code docs](https://code.claude.com/docs/en/statusline#available-data).

## Examples

A minimal line — model, context bar, cost:

```
{bright_green}[{json.model.display_name:short}]{reset} {bright_white}ctx{reset} {json.context_window.used_percentage:bar} {sep} {json.cost.total_cost_usd:usd}
```

Show lines changed and the current git worktree path (when present):

```
{json.model.display_name:short}{?json.workspace.git_worktree} {magenta}{json.workspace.git_worktree}{reset}{/} {green}+{json.cost.total_lines_added}{reset}/{red}-{json.cost.total_lines_removed}{reset}
```

(`workspace.git_worktree` is the repo's worktree path, not the branch name — see
the [available data](https://code.claude.com/docs/en/statusline#available-data).)

Two rows (git/dir on top, metrics below):

```
{bright_green}[{json.model.display_name:short}]{reset} {grey}{json.workspace.current_dir}{reset}\n{bright_white}ctx{reset} {json.context_window.used_percentage:bar} {sep} {json.cost.total_cost_usd:usd}
```

## Agentic self-service

A Claude session can change your status line on request. It will:

1. Edit `env.CLAUDE_STATUSLINE_FIELDS` in your `settings.json`.
2. Verify by piping a sample envelope through the script/binary and showing the line.
3. Leave the default short-circuit intact, so reverting to the default keeps the fast path.

See `CLAUDE.md` for the rules Claude follows (keep both front-ends in parity, keep
the default byte-identical, preserve the hot-path budget).

## Performance

The default (and the unset/empty case) uses the hardcoded fast path — **zero**
engine cost. A custom template adds only in-process string work and still makes
exactly **one `jq` call** on the bash hot path (the native binary forks nothing).
The throttle fast-path is unchanged, so bursts still reprint the cache fork-free.
