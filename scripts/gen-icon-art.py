#!/usr/bin/env python3
"""Generates icon artwork with Nano Banana 2 (Gemini image). Full-bleed square art;
scripts/compose-icon.swift applies the macOS squircle mask and shadow.
Usage: GEMINI_API_KEY=... scripts/gen-icon-art.py <out-dir> [model]"""
import base64, json, os, subprocess, sys

MODEL = sys.argv[2] if len(sys.argv) > 2 else "gemini-3.1-flash-image"
OUT = sys.argv[1]
KEY = os.environ["GEMINI_API_KEY"]

COMMON = ("Square 1:1 artwork for a macOS app icon, full bleed edge to edge: NO rounded corners, NO border, "
          "NO drop shadow, NO background outside the art, NO text, NO letters, NO logos. "
          "Premium Apple macOS Tahoe icon style: rich depth, soft lighting, subtle glassy highlights, crisp at small sizes, "
          "simple bold composition with one clear focal element. ")
PROMPTS = {
    "a-tabs-glass": COMMON + "A dark graphite terminal window seen straight on, filling the square. Along its top edge a row "
        "of three rounded browser-style tabs in soft blue, coral red and mint green, the blue one active and merging into the "
        "window. Inside the window a large glowing white chevron prompt '>' and a short block cursor. A small warm orange "
        "sparkle asterisk floats near the cursor, suggesting an AI agent.",
    "b-stacked-tabs": COMMON + "Three stacked translucent glass terminal cards fanned slightly like a deck, each with a colored "
        "tab on top (blue, coral, green) like tab groups. The front card is deep charcoal with a bright prompt chevron and "
        "cursor. Warm orange spark accent. Deep navy-to-black gradient background filling the square.",
    "c-minimal-chevron": COMMON + "Minimal: a deep midnight blue-to-black gradient field. Centered, a thick rounded chevron '>' "
        "prompt and underscore cursor in luminous off-white. Above it, three small pill-shaped colored tab chips "
        "(blue, coral, green) in a row. A tiny warm orange four-point spark near the cursor.",
    "d-terminal-folder": COMMON + "A sleek dark terminal screen with colored tab-group ribbons (blue, coral, green) hanging "
        "from the top like folder tabs, each ribbon a different height. On the screen a bright prompt '>_' in white. "
        "Subtle orange glow in one corner. Glassy, dimensional, Apple-like.",
}

for name, prompt in PROMPTS.items():
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
    img = next((p["inlineData"]["data"] for p in parts if "inlineData" in p), None)
    if not img:
        print(name, "no image:", json.dumps(resp)[:300]); continue
    path = os.path.join(OUT, name + ".png")
    open(path, "wb").write(base64.b64decode(img))
    print("wrote", path)
