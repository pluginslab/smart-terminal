#!/usr/bin/env python3
"""Mocked README screenshot (demo data only, nothing from a real machine).
Writes assets/screenshot.svg and, via headless Chrome, assets/screenshot.png (2x).

    python3 scripts/mock-screenshot.py
"""
import base64, html, os, subprocess, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W, H = 1440, 900
WX, WY, WW, WH = 110, 150, 1220, 660          # window (below the notification banner)
TB, ST = 38, 46                               # titlebar, tab strip heights
MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace"
UI = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif"

BLUE, RED, GREEN = "#8AB4F8", "#F28B82", "#81C995"
ORANGE = "#D97757"
TERM_BG, TEXT, DIM = "#131820", "#E6E6E6", "#8B949E"

def esc(s): return html.escape(s, quote=True)

def icon_data_uri():
    """Small copy of the real app icon for the notification banner."""
    src = os.path.join(ROOT, "Resources", "AppIcon.png")
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "i.png")
        subprocess.run(["sips", "-Z", "96", src, "--out", out], capture_output=True, check=True)
        return "data:image/png;base64," + base64.b64encode(open(out, "rb").read()).decode()

parts = []
add = parts.append

# ---------- backdrop ----------
add(f'''<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#1d2b4f"/><stop offset="0.55" stop-color="#2b1f3f"/><stop offset="1" stop-color="#3d2230"/>
  </linearGradient>
  <radialGradient id="glow" cx="0.78" cy="0.12" r="0.6">
    <stop offset="0" stop-color="#D97757" stop-opacity="0.35"/><stop offset="1" stop-color="#D97757" stop-opacity="0"/>
  </radialGradient>
  <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">
    <feDropShadow dx="0" dy="24" stdDeviation="28" flood-color="#000" flood-opacity="0.55"/>
  </filter>
  <filter id="bshadow" x="-20%" y="-40%" width="140%" height="200%">
    <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.45"/>
  </filter>
  <clipPath id="win"><rect x="{WX}" y="{WY}" width="{WW}" height="{WH}" rx="12"/></clipPath>
</defs>
<rect width="{W}" height="{H}" fill="url(#bg)"/>
<rect width="{W}" height="{H}" fill="url(#glow)"/>''')

# ---------- window ----------
add(f'<g filter="url(#shadow)"><rect x="{WX}" y="{WY}" width="{WW}" height="{WH}" rx="12" fill="{TERM_BG}"/></g>')
add('<g clip-path="url(#win)">')
add(f'<rect x="{WX}" y="{WY}" width="{WW}" height="{TB}" fill="#26272B"/>')
for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
    add(f'<circle cx="{WX + 22 + i * 20}" cy="{WY + TB / 2}" r="6.5" fill="{c}"/>')
title = "API — acme-storefront — ◐ Add Stripe webhook retries — caffeinate ◂ claude — 132×38"
add(f'<text x="{WX + WW / 2}" y="{WY + 24}" text-anchor="middle" font-family="{UI}" font-size="13" font-weight="600" fill="#C9C9CC">'
    f'{esc(title)}</text>')

# ---------- tab strip ----------
sy = WY + TB
add(f'<rect x="{WX}" y="{sy}" width="{WW}" height="{ST}" fill="#1E1F23"/>')
add(f'<rect x="{WX}" y="{sy + ST - 1}" width="{WW}" height="1" fill="#34353A"/>')
ty, th = sy + 7, ST - 14   # tab box
cy = sy + ST / 2           # vertical centre

def chip(x, name, color, extra_w=0, count=None, dot=None):
    w = 18 + len(name) * 7.4 + extra_w
    add(f'<rect x="{x}" y="{cy - 11}" width="{w}" height="22" rx="11" fill="{color}"/>')
    add(f'<text x="{x + 9}" y="{cy + 4.5}" font-family="{UI}" font-size="12" font-weight="700" fill="#202124">{esc(name)}</text>')
    if count is not None:
        bx = x + 14 + len(name) * 7.4
        add(f'<rect x="{bx}" y="{cy - 7.5}" width="17" height="15" rx="7.5" fill="#202124" fill-opacity="0.22"/>')
        add(f'<text x="{bx + 8.5}" y="{cy + 4}" text-anchor="middle" font-family="{UI}" font-size="10.5" font-weight="700" fill="#202124">{count}</text>')
    if dot:
        add(f'<circle cx="{x + w - 9}" cy="{cy}" r="3" fill="{dot}"/>')
    return x + w + 6

def tab(x, w, label, group=None, active=False, prefix=None, prefix_color=ORANGE, lead=None, close=False):
    if active:
        add(f'<rect x="{x}" y="{ty}" width="{w}" height="{th}" rx="7" fill="{TERM_BG}"/>')
    elif group:
        add(f'<rect x="{x}" y="{ty}" width="{w}" height="{th}" rx="7" fill="{group}" fill-opacity="0.13"/>')
    else:
        add(f'<rect x="{x}" y="{ty}" width="{w}" height="{th}" rx="7" fill="#FFFFFF" fill-opacity="0.045"/>')
    if group:
        add(f'<rect x="{x + 2}" y="{ty + th - 2}" width="{w - 4}" height="2" fill="{group}"/>')
    tx = x + 11
    if lead == "dot":
        add(f'<circle cx="{tx + 3}" cy="{cy}" r="3.2" fill="{group}"/>'); tx += 13
    elif lead == "waiting":
        # speech bubble with "!" = Claude waits on a permission prompt
        add(f'<path d="M{tx} {cy - 6} a4 4 0 0 1 4 -4 h7 a4 4 0 0 1 4 4 v5 a4 4 0 0 1 -4 4 h-5 l-4 3 v-3 a4 4 0 0 1 -2 -4 z" fill="{ORANGE}"/>')
        add(f'<text x="{tx + 7.5}" y="{cy + 2.5}" text-anchor="middle" font-family="{UI}" font-size="9" font-weight="900" fill="#1E1F23">!</text>')
        tx += 20
    weight = "600" if active else "400"
    fill = TEXT if active else "#A9ABB2"
    pre = f'<tspan fill="{prefix_color}">{esc(prefix)} </tspan>' if prefix else ""
    add(f'<text x="{tx}" y="{cy + 4.5}" font-family="{UI}" font-size="12.5" font-weight="{weight}" fill="{fill}">{pre}{esc(label)}</text>')
    if close:
        add(f'<text x="{x + w - 17}" y="{cy + 4.5}" font-family="{UI}" font-size="12" fill="#8B8D94">✕</text>')
    return x + w + 2

x = WX + 10
x = chip(x, "API", BLUE)
x = tab(x, 258, "Add Stripe webhook retries", BLUE, active=True, prefix="◐", close=True)
x = tab(x, 142, "server logs", BLUE, lead="dot")
x = tab(x, 118, "db shell", BLUE) + 6
x = chip(x, "Infra", RED, extra_w=34, count=3, dot=ORANGE)
x = chip(x, "Docs", GREEN)
x = tab(x, 212, "Release notes v2.1", GREEN, lead="waiting", prefix="✳")
x = tab(x, 96, "~") + 6
add(f'<text x="{x + 4}" y="{cy + 6}" font-family="{UI}" font-size="18" font-weight="300" fill="#C9C9CC">+</text>')

# ---------- terminal: a Claude Code session ----------
lx, ly, lh = WX + 22, sy + ST + 30, 21
# Claude Code's welcome box, drawn as a shape (box-drawing chars misalign around ✻).
add(f'<rect x="{lx}" y="{ly - 16}" width="420" height="56" rx="8" fill="none" stroke="{ORANGE}" stroke-opacity="0.8"/>')
add(f'<text x="{lx + 14}" y="{ly + 4}" font-family="{MONO}" font-size="14.5"><tspan fill="{ORANGE}">✻</tspan><tspan fill="{TEXT}" font-weight="700"> Claude Code</tspan></text>')
add(f'<text x="{lx + 30}" y="{ly + 26}" font-family="{MONO}" font-size="14.5" fill="{DIM}">~/code/acme-storefront</text>')
lines = [
    [], [], [], [],
    [(DIM, "> "), (TEXT, "add retries with exponential backoff to the Stripe webhook handler")],
    [],
    [(TEXT, "⏺ I'll add bounded retries with jitter and keep the handler idempotent.")],
    [],
    [(GREEN, "⏺ "), (TEXT, "Read"), (DIM, "(src/webhooks/stripe.ts)")],
    [(DIM, "  ⎿  Read 142 lines")],
    [(GREEN, "⏺ "), (TEXT, "Update"), (DIM, "(src/webhooks/stripe.ts)")],
    [(DIM, "  ⎿  Updated src/webhooks/stripe.ts with 18 additions and 3 removals")],
    [(DIM, "      41 "), (GREEN, "+  const delay = Math.min(2 ** attempt * 250, 8_000)")],
    [(DIM, "      42 "), (GREEN, "+  await sleep(delay + jitter(100))")],
    [(DIM, "      43 "), (RED,   "-  await sleep(1000)")],
    [(GREEN, "⏺ "), (TEXT, "Bash"), (DIM, "(npm test -- webhooks)")],
    [(DIM, "  ⎿  "), (GREEN, "✓ 24 passed"), (DIM, " (1.8s)")],
    [],
    [(ORANGE, "◐ "), (ORANGE, "Verifying idempotency keys…"), (DIM, " (12s · esc to interrupt)")],
    [],
    [(DIM, "─" * 124)],
    [(DIM, "> "), (TEXT, "▌")],
    [(DIM, "  ⏵⏵ bypass permissions on (shift+tab to cycle)")],
]
for i, segs in enumerate(lines):
    if not segs:
        continue
    spans = "".join(f'<tspan fill="{c}">{esc(t)}</tspan>' for c, t in segs)
    add(f'<text x="{lx}" y="{ly + i * lh}" font-family="{MONO}" font-size="14.5" xml:space="preserve">{spans}</text>')
add('</g>')
add(f'<rect x="{WX + 0.5}" y="{WY + 0.5}" width="{WW - 1}" height="{WH - 1}" rx="11.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.12"/>')

# ---------- notification banner ----------
nx, ny, nw, nh = W - 470, 30, 440, 84
add(f'<g filter="url(#bshadow)"><rect x="{nx}" y="{ny}" width="{nw}" height="{nh}" rx="20" fill="#2C2D33" fill-opacity="0.94"/></g>')
add(f'<rect x="{nx + 0.5}" y="{ny + 0.5}" width="{nw - 1}" height="{nh - 1}" rx="19.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.14"/>')
add(f'<image href="{icon_data_uri()}" x="{nx + 16}" y="{ny + 18}" width="48" height="48"/>')
add(f'<text x="{nx + 78}" y="{ny + 30}" font-family="{UI}" font-size="13.5" font-weight="700" fill="#F2F2F4">Claude needs you</text>')
add(f'<text x="{nx + nw - 16}" y="{ny + 30}" text-anchor="end" font-family="{UI}" font-size="11.5" fill="#9A9CA3">now</text>')
add(f'<text x="{nx + 78}" y="{ny + 50}" font-family="{UI}" font-size="12.5" fill="#D6D7DB">Docs · Release notes v2.1</text>')
add(f'<text x="{nx + 78}" y="{ny + 68}" font-family="{UI}" font-size="12.5" fill="#9A9CA3">Waiting: permission prompt</text>')

svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">\n'
       + "\n".join(parts) + "\n</svg>\n")
os.makedirs(os.path.join(ROOT, "assets"), exist_ok=True)
svg_path = os.path.join(ROOT, "assets", "screenshot.svg")
open(svg_path, "w").write(svg)

chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
png_path = os.path.join(ROOT, "assets", "screenshot.png")
if os.path.exists(chrome):
    # Chrome honours the SVG's declared size (qlmanage pads and rescales).
    subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    f"--window-size={W},{H}", "--force-device-scale-factor=2",
                    f"--screenshot={png_path}", "file://" + svg_path], capture_output=True)
print("wrote", svg_path, "and", png_path if os.path.exists(png_path) else "(no PNG: Chrome not found)")
