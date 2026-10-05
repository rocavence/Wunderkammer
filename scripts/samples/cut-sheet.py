#!/usr/bin/env python3
"""把 6 × 5 的拼貼圖（無版權）切成一件一張：極簡家電是預設圖組，咖啡豆、交通標誌、旅遊物件是示範展室。

用法：scripts/samples/cut-sheet.py <拼貼圖> <組名>   輸出 build/samples/<組名>/（含 credits.json）
組名：products、coffee、signs、travel
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops

COLS, ROWS = 6, 5
# Left to right, top to bottom: what each piece is, and what kind of thing it is.
PRODUCTS = [
    ("Radio", "audio"), ("Wall Clock", "clock"), ("Calculator", "desk"), ("Record Player", "audio"), ("Table Lamp", "light"), ("Camera", "desk"),
    ("Toaster", "kitchen"), ("Coffee Maker", "kitchen"), ("Kettle", "kitchen"), ("Pocket Radio", "audio"), ("Wristwatch", "clock"), ("Speaker", "audio"),
    ("Record Player", "audio"), ("Desk Clock", "clock"), ("Desk Fan", "home"), ("Speaker", "audio"), ("Shaver", "care"), ("Projector", "desk"),
    ("Hair Dryer", "care"), ("Kitchen Scale", "kitchen"), ("Desk Tidy", "desk"), ("Portable Radio", "audio"), ("Toaster", "kitchen"), ("Blender", "kitchen"),
    ("Toothbrush", "care"), ("Speaker", "audio"), ("Turntable and Amplifier", "audio"), ("Humidifier", "home"), ("Desk Lamp", "light"), ("Portable Speaker", "audio"),
]
# Products sit alone in their cells and are trimmed to the piece; the photographs fill theirs and are kept whole.
TRIM = {"products"}
SETS = {
    "products": PRODUCTS,
    "coffee": [("Coffee Beans", "coffee")] * 30,
    "signs": [("Road Sign", "sign")] * 30,
    "travel": [("Travel Find", "travel")] * 30,
}


def band(counts, gap=4):
    """From the busiest line near the middle, out to the first run of empty lines each way."""
    mid = len(counts) // 2
    start = max(range(len(counts)), key=lambda i: counts[i] - abs(i - mid) * 0.5)
    lo = hi = start
    while lo > 0 and any(counts[max(lo - gap, 0):lo]):
        lo -= 1
    while hi < len(counts) - 1 and any(counts[hi + 1:hi + 1 + gap]):
        hi += 1
    return lo, hi + 1


def span(ink):
    """The piece in the middle of the cell, leaving out slivers of its neighbours."""
    px = ink.load()
    rows = [sum(1 for x in range(ink.width) if px[x, y]) for y in range(ink.height)]
    top, bottom = band(rows)
    cols = [sum(1 for y in range(top, bottom) if px[x, y]) for x in range(ink.width)]
    left, right = band(cols)
    return left, top, right, bottom


def lines(sheet, count, axis):
    """Where the thin grey lines between cells are; rows in these sheets aren't evenly spaced."""
    grey = sheet.convert("L")
    px = grey.load()
    length, across = (grey.height, grey.width) if axis == "rows" else (grey.width, grey.height)

    def score(i):
        hits = sum(1 for j in range(0, across, 2) if 222 <= (px[j, i] if axis == "rows" else px[i, j]) <= 246)
        return hits / (across / 2)

    edges = [0]
    for k in range(1, count):
        guess = round(k * length / count)
        best = max(range(guess - 45, guess + 45), key=score)
        edges.append(best if score(best) >= 0.5 else guess)
    return edges + [length]


def main():
    sheet = Image.open(sys.argv[1]).convert("RGB")
    name = sys.argv[2]
    pieces = SETS[name]
    out = Path("build/samples") / name
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*"):
        old.unlink()
    xs, ys = lines(sheet, COLS, "cols"), lines(sheet, ROWS, "rows")
    credits = []
    for i, (title, kind) in enumerate(pieces):
        col, row = i % COLS, i // COLS
        # Inside the cell, clear of the thin lines between cells.
        cell = sheet.crop((xs[col] + 4, ys[row] + 4, xs[col + 1] - 4, ys[row + 1] - 4))
        box = (0, 0, *cell.size)
        if name in TRIM:
            # The piece itself, with even room around it.
            ink = ImageChops.difference(cell, Image.new("RGB", cell.size, (250, 250, 250))).convert("L").point(lambda v: 255 if v > 18 else 0)
            box = span(ink)
            pad = round(max(box[2] - box[0], box[3] - box[1]) * 0.16)
            box = (max(box[0] - pad, 0), max(box[1] - pad, 0), min(box[2] + pad, cell.width), min(box[3] + pad, cell.height))
        file = f"{i:02d} {title}.png"
        cell.crop(box).save(out / file)
        credits.append({"file": file, "title": title, "kind": kind, "artist": None, "license": "No rights reserved"})
    (out / "credits.json").write_text(json.dumps(credits, ensure_ascii=False, indent=1))
    print(f"{len(credits)} 件 → {out}")


if __name__ == "__main__":
    main()
