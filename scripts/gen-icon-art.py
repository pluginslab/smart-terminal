#!/usr/bin/env python3
"""Generates icon artwork with Nano Banana Pro (Gemini image). Full-bleed square art;
scripts/compose-icon.swift applies the macOS squircle mask and shadow.
Usage: GEMINI_API_KEY=... scripts/gen-icon-art.py <out-dir> [model] [name,name,...]"""
import base64, json, os, subprocess, sys

MODEL = sys.argv[2] if len(sys.argv) > 2 else "gemini-3-pro-image-preview"  # Nano Banana Pro
OUT = sys.argv[1]
KEY = os.environ["GEMINI_API_KEY"]
ONLY = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else None  # optional comma-separated subset

COMMON = ("Square 1:1 artwork for a macOS app icon, full bleed edge to edge: the background colour fills the entire "
          "square to every edge. NO rounded corners, NO border or frame around the art, NO drop shadow outside the art, "
          "NO text, NO letters, NO numbers, NO logos. Premium Apple macOS Tahoe icon style: one bold, simple silhouette, "
          "soft studio lighting, subtle Liquid Glass highlights and gentle depth, large shapes with generous negative "
          "space so it stays crisp and legible at 16 pixels. Restrained palette. ")
SPARK = ("a chunky six-armed asterisk made of six thick rounded spokes radiating from the centre, in warm glowing "
         "orange (#E8783A)")
PROMPTS = {
    "a-slab-spark": COMMON + "A single thick dark graphite glass slab (a terminal screen) floating centred, slightly "
        "tilted toward the viewer, its face near-black with a soft inner glow. On the slab, left of centre, a large bold "
        "white chevron prompt shape, and in place of the cursor " + SPARK + ". Background: smooth deep charcoal-to-black "
        "gradient. Nothing else.",
    "b-tab-chips": COMMON + "Background: deep near-black graphite with a faint vertical gradient. Centred, a horizontal "
        "row of four fat rounded pill-shaped glass chips, like browser tab group labels, in blue, coral red, mint green "
        "and warm orange; the orange one is slightly larger and raised forward with a soft glow, as if active. The chips "
        "are thick, glossy, three-dimensional. Nothing else in the image.",
    "c-spark-cursor": COMMON + "Background: rich matte black with a very subtle radial lift in the centre. Centred and "
        "large, " + SPARK + ", rendered as a solid glossy three-dimensional glass object with a soft orange bloom on the "
        "background. Directly to its lower right, a short thick white underscore bar like a terminal cursor. Minimal, iconic.",
    "d-stacked-sessions": COMMON + "Three thick rounded-rectangle dark glass terminal panes stacked in depth, offset "
        "diagonally from back-left to front-right, each pane with a thin coloured top edge strip: blue at the back, green "
        "in the middle, orange at the front. The front pane shows a single bold white chevron prompt. Background: smooth "
        "deep navy-black gradient. Clean, geometric, not folders.",
    "e-chevron-tabs": COMMON + "Background: smooth deep indigo-to-black gradient. Centred, one huge thick rounded chevron "
        "prompt shape pointing right, made of frosted white Liquid Glass with luminous edges. Along the top of the square, "
        "small but bold, three short coloured tab bars (blue, green, orange) sit like a tab strip. Only these elements.",
    "f-window-tabbar": COMMON + "A straight-on dark terminal window that fills most of the square with a margin of warm "
        "light grey background around it. The window's top bar is a row of three solid coloured tabs: blue, green and "
        "orange, the orange one in front and merging into the dark window body. The window body is near-black and empty "
        "except for a single small glowing orange asterisk cursor near the upper left. Flat-ish but with Tahoe glass sheen.",
    "g-glass-orb-prompt": COMMON + "Background: deep warm black. Centred, a thick translucent smoky glass rounded square "
        "tile (like a keycap) floating with soft reflections; inside it, suspended, a bold white chevron prompt and next to "
        "it " + SPARK + ". Thin coloured light reflections of blue and green on the glass edges hint at tab colours.",
    "h-ring-of-tabs": COMMON + "Background: deep graphite black. Centred, " + SPARK + ", large and glossy, each of its six "
        "spokes capped with a small rounded tip of a different tab-group colour (blue, green, coral, violet, yellow, orange) "
        "so it reads as many sessions radiating from one hub. Bold, symmetrical, minimal.",
    # Round 2: refinements of the strongest round-1 directions (a, b, d, f).
    "a2-slab-tabs": COMMON + "A single thick dark graphite glass slab (a terminal screen) floating centred and large, "
        "seen almost straight on with a slight tilt, its face near-black with a soft inner glow. Along the slab's top "
        "edge, three short thick coloured tab bars sit side by side: blue, green and orange, the orange one brightest. On "
        "the slab face a large bold white chevron prompt shape followed by " + SPARK + " as the cursor. Background: smooth "
        "deep charcoal-to-black gradient filling the whole square.",
    "a3-slab-straight": COMMON + "A thick dark graphite glass slab (a terminal screen) seen perfectly straight on, centred, "
        "occupying about 70 percent of the square, with a polished bevelled edge catching a cool highlight on top. On its "
        "near-black face, centred, a big bold rounded white chevron prompt followed by " + SPARK + " standing in for the "
        "cursor, glowing softly onto the glass. Background: smooth slate-grey to black vertical gradient filling the whole "
        "square. Nothing else.",
    "b2-chips-prompt": COMMON + "Background: deep near-black graphite with a faint vertical gradient filling the whole "
        "square. In the upper third, a row of three fat rounded glossy pill chips like tab group labels: blue, green and "
        "orange. Below them, large and centred, a bold rounded white chevron prompt followed by a short thick white "
        "underscore cursor. Three-dimensional glass with soft reflections. Nothing else.",
    "d2-stacked-fullbleed": COMMON + "The background is a smooth deep navy-to-black gradient that fills the ENTIRE square "
        "edge to edge, no white anywhere. Floating in the centre, three thick dark glass terminal panes stacked in depth, "
        "offset diagonally from back-left to front-right, each with a glowing coloured rim: blue at the back, green in the "
        "middle, orange at the front. The front pane shows a single bold white chevron prompt and a small orange asterisk "
        "cursor. Clean, geometric.",
    "f2-window-prompt": COMMON + "Background: smooth deep graphite gradient filling the whole square. Centred, a large "
        "straight-on dark terminal window. Its top bar is a row of three solid tabs: blue, green and orange, the orange tab "
        "in front, slightly taller, merging seamlessly into the near-black window body. In the body, large and bold, a "
        "white chevron prompt followed by " + SPARK + ". Glossy Tahoe glass sheen on the window edges.",
    "d3-stacked-bold": COMMON + "The background is a smooth deep navy-to-black gradient that fills the ENTIRE square "
        "edge to edge. Filling most of the square, three thick dark glass terminal panes stacked in depth, offset "
        "diagonally from back-left to front-right, each with a bright glowing coloured rim: blue at the back, green in the "
        "middle, orange at the front. The front pane is the largest and shows a BIG bold white chevron prompt followed by "
        + SPARK + ", together spanning most of the pane's width. Clean, geometric, bold.",
}

for name, prompt in PROMPTS.items():
    if ONLY and name not in ONLY:
        continue
    body = {"contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {"responseModalities": ["IMAGE"], "imageConfig": {"aspectRatio": "1:1"}}}
    # curl, not urllib: python.org builds often lack a CA bundle.
    r = subprocess.run(["curl", "-sS", "--max-time", "240", "-H", "Content-Type: application/json",
                        "-H", f"x-goog-api-key: {KEY}", "-d", "@-",
                        f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"],
                       input=json.dumps(body).encode(), capture_output=True)
    try:
        resp = json.loads(r.stdout)
    except json.JSONDecodeError:
        print(name, "bad response:", r.stdout[:200], r.stderr[:200]); continue
    if "error" in resp:
        print(name, "error:", resp["error"].get("message", "")[:200]); continue
    parts = resp.get("candidates", [{}])[0].get("content", {}).get("parts", [])
    inline = next((p["inlineData"] for p in parts if "inlineData" in p), None)
    if not inline:
        print(name, "no image:", json.dumps(resp)[:300]); continue
    path = os.path.join(OUT, name + ".png")
    open(path, "wb").write(base64.b64decode(inline["data"]))
    if inline.get("mimeType", "image/png") != "image/png":  # the Pro model returns JPEG
        subprocess.run(["sips", "-s", "format", "png", path, "--out", path], capture_output=True)
    print("wrote", path)
