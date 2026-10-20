# /// script
# requires-python = ">=3.11"
# dependencies = ["cairosvg", "pillow"]
# ///
"""Render the schematic widescreen demo: uv run docs/assets/render-widescreen-demo.py.

Requires ffmpeg and Cairo. With Homebrew on macOS, use:
DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix)/lib" uv run docs/assets/render-widescreen-demo.py
--preview-only renders the poster and a storyboard without video.
Window identities persist across transitions. Geometry follows adaptiveLayout.swift:
one column/row = 33%/90%, two columns or multiple rows = 66% width,
three columns = full width, multiple rows = full height. Gaps remain inside it.
"""

from __future__ import annotations

import argparse
import importlib.util
import math
import subprocess
import sys
import tempfile
from pathlib import Path

import cairosvg
from PIL import Image


HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("demo", HERE / "render-demos.py")
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)
rect, label, window = demo.rect, demo.label, demo.window
WIDTH, HEIGHT, FPS = 1200, 820, 20
SCREEN = (150, 174, 900, 506.25)  # A 16:9 display, like the user's large Dell.
GAP = 7
TRANSITION, HOLD = 0.85, 2.15
STEP = TRANSITION + HOLD
NAMES = ["Writing", "Reference", "Notes", "Terminal", "Tasks", "Calendar"]
ACCENTS = ["#7589de", "#64aa9b", "#c49b61", "#ac83c4", "#73a1bf", "#b57d8e"]


def bounds(columns, rows):
    x, y, w, h = SCREEN
    x, y, w, h = x + GAP, y + 24 + GAP, w - 2 * GAP, h - 24 - 2 * GAP
    width = w * (0.33 if columns == 1 and rows == 1 else 0.66 if columns < 3 else 1)
    height = h * (0.9 if rows == 1 else 1)
    return x + (w - width) / 2, y + (h - height) / 2, width, height


def grid(columns, rows, ids):
    x, y, w, h = bounds(columns, rows)
    tile_w, tile_h = (w - GAP * (columns - 1)) / columns, (h - GAP * (rows - 1)) / rows
    return {
        ident: (x + (i % columns) * (tile_w + GAP), y + (i // columns) * (tile_h + GAP), tile_w, tile_h)
        for i, ident in enumerate(ids)
    }


def spanning():
    x, y, w, h = bounds(2, 2)
    half_w, half_h = (w - GAP) / 2, (h - GAP) / 2
    return {0: (x, y, half_w, half_h), 1: (x + half_w + GAP, y, half_w, half_h),
            2: (x, y + half_h + GAP, w, half_h)}


SCENES = [
    ("One window", "A comfortable width, centred", "33% width · 90% height", grid(1, 1, [0])),
    ("Two side by side", "More room, with margins on every side", "66% width · 90% height", grid(2, 1, [0, 1])),
    ("Three across", "Use the width; keep space above and below", "Full width · 90% height", grid(3, 1, [0, 1, 2])),
    ("Move one below", "Keep the side margins; use the height", "66% width · full height", spanning()),
    ("Three in a vertical stack", "The stack keeps the width of two columns", "66% width · full height", grid(1, 3, [0, 1, 2])),
    ("Two in a vertical stack", "Same generous width, fewer rows", "66% width · full height", grid(1, 2, [0, 1])),
    ("Three columns, two rows", "A larger layout uses the whole display", "Full width · full height", grid(3, 2, list(range(6)))),
]
DURATION = len(SCENES) * STEP


def validate_scenes():
    sx, sy, sw, sh = SCREEN
    for _, _, _, tiles in SCENES:
        for x, y, w, h in tiles.values():
            assert w > 0 and h > 0
            assert sx <= x and sy <= y and x + w <= sx + sw and y + h <= sy + sh
        boxes = list(tiles.values())
        for i, (x, y, w, h) in enumerate(boxes):
            for xx, yy, ww, hh in boxes[i + 1:]:
                assert x + w <= xx or xx + ww <= x or y + h <= yy or yy + hh <= y


def draw(time):
    # Begin with a readable still. The final transition returns to that same state.
    index = int(time // STEP) % len(SCENES)
    local = time % STEP
    next_index = (index + 1) % len(SCENES)
    current, following = SCENES[index], SCENES[next_index]
    amount = demo.ease((local - HOLD) / TRANSITION)
    active = current if amount < 0.5 else following
    caption_opacity = 1 - math.sin(math.pi * amount) * 0.85
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="820" viewBox="0 0 1200 820">',
        '<defs><linearGradient id="bg" x2="1" y2="1"><stop stop-color="#111a31"/>'
        '<stop offset="1" stop-color="#101024"/></linearGradient>'
        '<linearGradient id="screen" x2="1" y2="1"><stop stop-color="#343d68"/>'
        '<stop offset="1" stop-color="#1e2948"/></linearGradient></defs>',
        rect(0, 0, WIDTH, HEIGHT, "url(#bg)"),
        rect(42, 36, 11, 11, "#8e9fff", 3),
        label(64, 48, "AEROSPACE ALPHA", 17, "#aebbf1", 700),
        label(42, 99, "Adaptive widescreen layouts", 40, "#f1f3ff", 700),
        label(43, 135, "Space adapts as you add and rearrange windows.", 22, "#aab5d2"),
        demo.monitor(*SCREEN, ""),
    ]
    # Frame, title band and accent keep each window identifiable while it moves.
    for ident in sorted(current[3].keys() | following[3].keys()):
        start = current[3].get(ident, following[3].get(ident))
        end = following[3].get(ident, current[3].get(ident))
        opacity = amount if ident not in current[3] else 1 - amount if ident not in following[3] else 1
        coordinates = [demo.mix(a, b, amount) for a, b in zip(start, end)]
        parts.append(window(*coordinates, NAMES[ident], opacity, ACCENTS[ident]))
    parts.extend([
        label(150, 724, active[0], 25, "#f1f3ff", 650, opacity=caption_opacity),
        label(150, 754, active[1], 19, "#b6c2df", opacity=caption_opacity),
        label(1050, 724, active[2], 18, "#aebbf1", 500, "end", caption_opacity),
        rect(42, 779, 1116, 1, "#405075", opacity=0.65),
        label(43, 805, "Illustrated layouts · configurable margins · enabled per monitor", 16, "#9eacc9"),
    ])
    for i in range(len(SCENES)):
        parts.append(rect(943 + 16 * i, 795, 8, 5, "#aebbf1" if i == index else "#405075", 2))
    return "".join(parts) + "</svg>"


def render(preview_only):
    validate_scenes()
    name = "adaptive-widescreen-demo"
    poster = draw(3 * STEP + 1)
    cairosvg.svg2png(bytestring=poster.encode(), write_to=str(HERE / f"{name}-preview.png"))
    # Keep the review contact sheet outside the repository; only the final assets ship.
    sheet = Image.new("RGB", (WIDTH * 2, HEIGHT * 4), "#101024")
    with tempfile.TemporaryDirectory(prefix="aerospace-wide-") as temp:
        path = Path(temp)
        for i in range(len(SCENES)):
            png = path / f"scene-{i}.png"
            cairosvg.svg2png(bytestring=draw(i * STEP + 1).encode(), write_to=str(png))
            with Image.open(png) as im:
                sheet.paste(im, ((i % 2) * WIDTH, (i // 2) * HEIGHT))
        sheet.resize((1200, 1640)).save("/tmp/aerospace-widescreen-storyboard.png")
        if preview_only:
            return
        for i in range(round(DURATION * FPS)):
            cairosvg.svg2png(bytestring=draw(i / FPS).encode(), write_to=str(path / f"{i:04d}.png"))
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-framerate", str(FPS),
            "-i", str(path / "%04d.png"), "-c:v", "libx264", "-crf", "21", "-pix_fmt", "yuv420p",
            "-movflags", "+faststart", str(HERE / f"{name}.mp4"),
        ], check=True)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-framerate", str(FPS),
            "-i", str(path / "%04d.png"), "-filter_complex",
            "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];"
            "[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle",
            "-loop", "0", str(HERE / f"{name}.gif"),
        ], check=True)
    print(f"Rendered {DURATION:.0f}s demo: {HERE / name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview-only", action="store_true")
    render(parser.parse_args().preview_only)
