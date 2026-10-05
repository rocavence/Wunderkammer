#!/usr/bin/env python3
"""把 6 × 5 的拼貼圖（無版權）切成一件一張：極簡家電是預設圖組，咖啡豆、交通標誌、旅遊物件是示範展室。

用法：scripts/samples/cut-sheet.py <拼貼圖> <組名>   輸出 build/samples/<組名>/（含 credits.json）
組名：nordic（預設圖組）、products、products2、coffee、signs、travel
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
TRIM = {"products", "products2"}
PRODUCTS2 = [
    ("Wall Clock", "clock"), ("Record Player", "audio"), ("Alarm Clock", "clock"), ("Calculator", "desk"), ("Portable Speaker", "audio"), ("Spotlight", "light"),
    ("Water Jug", "kitchen"), ("Letter Tray", "desk"), ("Coffee Grinder", "kitchen"), ("Pour-over Dripper", "kitchen"), ("Storage Box", "home"), ("Kettle", "kitchen"),
    ("Speaker", "audio"), ("Stapler", "desk"), ("Tape Dispenser", "desk"), ("Pen Cup", "desk"), ("Drawer Unit", "desk"), ("Desk Fan", "home"),
    ("Ashtray", "home"), ("Thermometer", "home"), ("Cake Stand", "kitchen"), ("Watering Can", "home"), ("Flashlight", "light"), ("Storage Jar", "kitchen"),
    ("Wall Hooks", "home"), ("Pen Holders", "desk"), ("Lint Brush", "care"), ("Desk Organizer", "desk"), ("Mirror", "care"), ("Pedal Bin", "home"),
]
_S, _T, _K, _B, _L, _D, _P, _C, _X = "seating", "table", "storage", "bed", "light", "decor", "plant", "kitchen", "textile"
NORDIC = [
    ("Wooden Chair", _S), ("Dining Chair", _S), ("Armchair", _S), ("Sofa", _S), ("Sectional Sofa", _S),
    ("Coffee Table", _T), ("Side Table", _T), ("Stool", _S), ("Stacking Stools", _S), ("Side Table", _T),
    ("Dining Table", _T), ("Dining Table", _T), ("Pedestal Table", _T), ("Armchair", _S), ("Swivel Chair", _S),
    ("Lounge Chair", _S), ("Pouf", _S), ("Pouf", _S), ("Bench", _T), ("Sideboard", _K),
    ("Sideboard", _K), ("Dresser", _K), ("Cabinet", _K), ("Dresser", _K), ("Shelf", _K),
    ("Shelf", _K), ("Cube Shelf", _K), ("Cube Shelf", _K), ("Bookcase", _K), ("Storage Shelf", _K),
    ("Bed", _B), ("Bed", _B), ("Bed", _B), ("Nightstand", _B), ("Nightstand", _B),
    ("Nightstand", _B), ("Office Chair", _S), ("Chair", _S), ("Chair", _S), ("Folding Chair", _S),
    ("Table Lamp", _L), ("Table Lamp", _L), ("Desk Lamp", _L), ("Desk Lamp", _L), ("Table Lamp", _L),
    ("Floor Lamp", _L), ("Pendant Lamp", _L), ("Pendant Lamp", _L), ("Pendant Lamp", _L), ("Pendant Lamp", _L),
    ("Wall Clock", _D), ("Mirror", _D), ("Art Print", _D), ("Vase", _D), ("Plant", _P),
    ("Plant", _P), ("Plant", _P), ("Plant", _P), ("Plant", _P), ("Branches in a Vase", _P),
    ("Dishes", _C), ("Mugs", _C), ("Utensil Holder", _C), ("Storage Jars", _C), ("Bath Set", _D), ("Diffuser", _D),
    ("Vases", _D), ("Blankets", _X), ("Cushions", _X), ("Cushion", _X), ("Knot Pillow", _X),
    ("Basket", _K), ("Laundry Bag", _K), ("Pegboard", _K), ("Trolley", _K), ("Step Stool", _S), ("Watering Can", _P),
    ("Tissue Box", _D), ("Bookends", _D), ("Bookends", _D), ("Glass Vase", _D), ("Vase", _D),
]
# Sheets whose rows have different numbers of cells: the lines are found row by row.
FREE_GRID = {"nordic"}
SETS = {
    "nordic": NORDIC,
    "products": PRODUCTS,
    "products2": PRODUCTS2,
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


def runs(flags, merge=10):
    """Stretches of True, close ones joined, as (start, end)."""
    out = []
    for i, on in enumerate(flags):
        if not on:
            continue
        if out and i - out[-1][1] <= merge:
            out[-1][1] = i
        else:
            out.append([i, i])
    return out


def free_cells(sheet):
    """Every cell, row by row, from the white lines between them."""
    grey = sheet.convert("L")
    px = grey.load()
    w, h = grey.size
    rows = runs([sum(px[x, y] >= 250 for x in range(0, w, 2)) / (w / 2) > 0.6 for y in range(h)], merge=2)
    cuts = [0] + [(a + b) // 2 for a, b in rows if 20 < a < h - 20] + [h]
    cells = []
    for top, bottom in zip(cuts, cuts[1:]):
        y0, y1 = top + 6, bottom - 6
        cols = runs([sum(px[x, y] >= 250 for y in range(y0, y1, 2)) / ((y1 - y0) / 2) > 0.85 for x in range(w)])
        edges = [b for a, b in cols[:1]] + [(a + b) // 2 for a, b in cols[1:-1]] + [a for a, b in cols[-1:]]
        cells += [(left + 3, top + 3, right - 3, bottom - 3) for left, right in zip(edges, edges[1:])]
    return cells


def main():
    sheet = Image.open(sys.argv[1]).convert("RGB")
    name = sys.argv[2]
    pieces = SETS[name]
    out = Path("build/samples") / name
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*"):
        old.unlink()
    if name in FREE_GRID:
        boxes = free_cells(sheet)
    else:
        xs, ys = lines(sheet, COLS, "cols"), lines(sheet, ROWS, "rows")
        # Inside each cell, clear of the thin lines between cells.
        boxes = [(xs[i % COLS] + 4, ys[i // COLS] + 4, xs[i % COLS + 1] - 4, ys[i // COLS + 1] - 4) for i in range(len(pieces))]
    assert len(boxes) == len(pieces), f"{len(boxes)} cells for {len(pieces)} pieces"
    credits = []
    for i, (title, kind) in enumerate(pieces):
        cell = sheet.crop(boxes[i])
        box = (0, 0, *cell.size)
        if name in TRIM:
            # The piece itself, with even room around it.
            ink = ImageChops.difference(cell, Image.new("RGB", cell.size, (250, 250, 250))).convert("L").point(lambda v: 255 if v > 18 else 0)
            box = span(ink)
            pad = round(max(box[2] - box[0], box[3] - box[1]) * 0.16)
            box = (max(box[0] - pad, 0), max(box[1] - pad, 0), min(box[2] + pad, cell.width), min(box[3] + pad, cell.height))
        file = f"{name[-1] if name[-1].isdigit() else ''}{i:02d} {title}.png"
        cell.crop(box).save(out / file)
        credits.append({"file": file, "title": title, "kind": kind, "artist": None, "license": "No rights reserved"})
    (out / "credits.json").write_text(json.dumps(credits, ensure_ascii=False, indent=1))
    print(f"{len(credits)} 件 → {out}")


if __name__ == "__main__":
    main()
