#!/usr/bin/env python3
"""Generate LinkedIn/social visuals for the status-line write-up. Pillow only."""
import math
from PIL import Image, ImageDraw, ImageFont

S = 2  # supersample
W, H = 1080, 1080
FONT = "/usr/share/fonts/liberation/LiberationSans-Regular.ttf"
FONTB = "/usr/share/fonts/liberation/LiberationSans-Bold.ttf"
MONO = "/usr/share/fonts/liberation/LiberationMono-Regular.ttf"
MONOB = "/usr/share/fonts/liberation/LiberationMono-Bold.ttf"

BG = (13, 17, 23)        # #0d1117
PANEL = (22, 27, 34)     # #161b22
TEXT = (230, 237, 243)   # #e6edf3
MUTED = (139, 148, 158)  # #8b949e
ACCENT = (63, 185, 80)   # #3fb950

def f(path, px): return ImageFont.truetype(path, px * S)
def hx(c): return tuple(int(c[i:i+2], 16) for i in (1, 3, 5))

def canvas():
    im = Image.new("RGB", (W * S, H * S), BG)
    return im, ImageDraw.Draw(im)

def save(im, name):
    im = im.resize((W, H), Image.LANCZOS)
    im.save(f"/home/radu/tmp/claude-code-statusline/docs/assets/{name}")
    print("wrote", name)

def center(d, cx, y, text, font, fill):
    w = d.textlength(text, font=font)
    d.text((cx - w / 2, y), text, font=font, fill=fill)

def rrect(d, box, r, fill):
    d.rounded_rectangle(box, radius=r * S, fill=fill)

def footer(d):
    center(d, W * S / 2, (H - 52) * S, "github.com/radumarias/claude-code-statusline",
           f(MONO, 20), MUTED)

# ---------------- 1. The journey (log-scale bars) ----------------
def journey():
    im, d = canvas()
    center(d, W * S / 2, 70 * S, "From 73 ms to 0.34 ms", f(FONTB, 60), TEXT)
    center(d, W * S / 2, 150 * S, "one Claude Code status line · bash  →  native Rust",
           f(FONT, 30), MUTED)

    bars = [
        ("Bash  ·  12× jq forks", 73.0, "#f85149"),
        ("Bash  ·  1 jq + builtins", 6.0, "#fb8500"),
        ("Bash  ·  throttled cache", 1.8, "#e3b341"),
        ("Native  ·  dynamic", 0.57, "#56d364"),
        ("Native  ·  static glibc", 0.38, "#3fb950"),
        ("Native  ·  static musl", 0.34, "#2ea043"),
    ]
    x0, top, bw = 70 * S, 200 * S, (W - 140) * S
    step, bh = 104 * S, 50 * S
    lo, hi = math.log10(0.1), math.log10(100)
    def frac(v): return (math.log10(v) - lo) / (hi - lo)

    for i, (name, v, col) in enumerate(bars):
        y = top + i * step
        hero = (i == len(bars) - 1)
        d.text((x0, y), name, font=f(FONTB if hero else FONT, 27),
               fill=ACCENT if hero else TEXT)
        by = y + 36 * S
        # track (accent outline on the hero row)
        rrect(d, [x0, by, x0 + bw, by + bh], 12, PANEL)
        if hero:
            d.rounded_rectangle([x0, by, x0 + bw, by + bh], radius=12 * S,
                                outline=ACCENT, width=2 * S)
        w = max(int(bw * frac(v)), 64 * S)
        rrect(d, [x0, by, x0 + w, by + bh], 12, hx(col))
        # value label
        lab = f"{v:g} ms"
        lf = f(MONOB, 29)
        lw = d.textlength(lab, font=lf)
        inside = w - lw - 36 * S > 0
        lx = x0 + w - lw - 18 * S if inside else x0 + w + 18 * S
        d.text((lx, by + 11 * S), lab, font=lf, fill=(13, 17, 23) if inside else TEXT)

    # highlight the win
    yb = top + len(bars) * step + 22 * S
    center(d, W * S / 2, yb, "≈ 215× faster   ·   zero forks   ·   < 1 MB",
           f(FONTB, 34), ACCENT)
    center(d, W * S / 2, yb + 50 * S,
           "log scale — each step is a different order of magnitude",
           f(FONT, 22), MUTED)
    footer(d)
    save(im, "01-journey.png")

# ---------------- 2. Where the time goes (true-scale sliver) ----------------
def where_time_goes():
    im, d = canvas()
    center(d, W * S / 2, 78 * S, "Where the time actually goes", f(FONTB, 56), TEXT)
    center(d, W * S / 2, 156 * S, "one native invocation  ≈  0.34 ms  =  ~340 µs",
           f(FONT, 30), MUTED)

    x0, bw = 70 * S, (W - 140) * S
    by, bh = 360 * S, 96 * S
    logic_frac = 6.0 / 340.0
    lw = max(int(bw * logic_frac), 14 * S)
    spawn_w = bw - lw
    rrect(d, [x0, by, x0 + bw, by + bh], 14, PANEL)
    # spawn (blue) + logic (green sliver)
    d.rounded_rectangle([x0, by, x0 + spawn_w, by + bh], radius=14 * S, fill=hx("#1f6feb"))
    d.rectangle([x0 + spawn_w - 20 * S, by, x0 + spawn_w, by + bh], fill=hx("#1f6feb"))
    d.rounded_rectangle([x0 + spawn_w, by, x0 + bw, by + bh], radius=14 * S, fill=ACCENT)
    d.rectangle([x0 + spawn_w, by, x0 + spawn_w + 20 * S, by + bh], fill=ACCENT)

    center(d, x0 + spawn_w / 2, by + 18 * S, "process spawn", f(FONTB, 34), (255, 255, 255))
    center(d, x0 + spawn_w / 2, by + 56 * S,
           "execve · mmap libc · relocations · runtime init", f(FONT, 22), (200, 222, 255))
    # callout to the green sliver (point left — the sliver hugs the right edge)
    sx = x0 + spawn_w + lw / 2
    elbow = by - 92 * S
    d.line([sx, by - 14 * S, sx, elbow], fill=ACCENT, width=2 * S)
    d.line([sx, elbow, sx - 180 * S, elbow], fill=ACCENT, width=2 * S)
    rx = sx - 196 * S
    t1, t2 = "your logic", "parse + render ≈ 6 µs"
    f1, f2 = f(FONTB, 26), f(MONO, 22)
    d.text((rx - d.textlength(t1, font=f1), elbow - 60 * S), t1, font=f1, fill=ACCENT)
    d.text((rx - d.textlength(t2, font=f2), elbow - 24 * S), t2, font=f2, fill=MUTED)

    center(d, W * S / 2, 560 * S, "≈ 99% is just being born", f(FONTB, 64), TEXT)
    center(d, W * S / 2, 660 * S,
           "the logic is ~6 µs — an empty  fn main()  spawns just as fast.",
           f(FONT, 30), MUTED)
    center(d, W * S / 2, 720 * S,
           "you cannot out-code a cost that isn't in your code.",
           f(FONT, 30), MUTED)
    # two stat chips
    def chip(cx, big, small, col):
        bw2 = 360 * S
        rrect(d, [cx - bw2 / 2, 800 * S, cx + bw2 / 2, 920 * S], 16, PANEL)
        center(d, cx, 820 * S, big, f(MONOB, 44), col)
        center(d, cx, 878 * S, small, f(FONT, 24), MUTED)
    chip(W * S * 0.30, "~334 µs", "process spawn  (98%)", hx("#58a6ff"))
    chip(W * S * 0.70, "~6 µs", "your logic  (2%)", ACCENT)
    footer(d)
    save(im, "02-where-time-goes.png")

# ---------------- 3. 89 agents funnel ----------------
def funnel():
    im, d = canvas()
    center(d, W * S / 2, 76 * S, "89 agents. 169 ideas. One win.", f(FONTB, 54), TEXT)
    center(d, W * S / 2, 152 * S,
           "three parallel adversarial brainstorming sessions", f(FONT, 30), MUTED)

    rows = [
        (169, "raw ideas   (120 brainstorm + 49 debate)", 920, "#58a6ff"),
        (22, "canonical candidates", 600, "#d29922"),
        (6, "survived review", 360, "#3fb950"),
        (1, "the new win:  musl", 230, "#2ea043"),
    ]
    top, step, bh = 250 * S, 150 * S, 104 * S
    cx = W * S / 2
    for i, (n, label, wpx, col) in enumerate(rows):
        y = top + i * step
        w = wpx * S
        hero = (i == len(rows) - 1)
        rrect(d, [cx - w / 2, y, cx + w / 2, y + bh], 16, hx(col))
        if hero:
            d.rounded_rectangle([cx - w / 2, y, cx + w / 2, y + bh], radius=16 * S,
                                outline=(255, 255, 255), width=2 * S)
        num = str(n)
        nf = f(MONOB, 56)
        nx = cx - w / 2 + 28 * S
        d.text((nx, y + 20 * S), num, font=nf, fill=(13, 17, 23))
        numw = d.textlength(num, font=nf)
        lf = f(FONTB if hero else FONT, 27)
        lx = nx + numw + 26 * S
        if lx + d.textlength(label, font=lf) < cx + w / 2 - 20 * S:
            d.text((lx, y + 36 * S), label, font=lf, fill=(13, 17, 23))
        else:
            d.text((cx + w / 2 + 26 * S, y + 36 * S), label, font=lf, fill=TEXT)
        if i < len(rows) - 1:
            ty = y + bh + 14 * S
            tw = 15 * S
            d.polygon([(cx - tw, ty), (cx + tw, ty), (cx, ty + 20 * S)], fill=MUTED)

    center(d, W * S / 2, 864 * S,
           "every idea default-refuted — survives only if it can't be killed",
           f(FONT, 22), MUTED)
    center(d, W * S / 2, 906 * S,
           "bigger spawn wins, outside the brainstorm:  static linking · no_main · absolute path (no /bin/sh)",
           f(MONO, 18), ACCENT)
    center(d, W * S / 2, 948 * S,
           "rejected:  daemon front-end 2.6× slower · core-pinning 10× worse p50",
           f(MONO, 18), hx("#f85149"))
    footer(d)
    save(im, "03-funnel.png")

journey()
where_time_goes()
funnel()
