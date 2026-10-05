#!/usr/bin/env python3
"""網站收藏牆的素材：把示範收藏（scripts/samples/fetch-samples.py 下載的 CC0 圖片）縮成小圖，
寫出 site/assets/wall.json（尺寸、標題、作者、搜尋示範用的標籤與主色），
以及示範展室的封面（site/assets/rooms/）。

用法：python3 scripts/site/wall.py
"""
import colorsys
import hashlib
import io
import json
import re
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).parent.parent.parent
SAMPLES = ROOT / "build/samples"
# The default set: 82 pieces of Nordic furniture and things for the home.
SOURCES = [SAMPLES / "nordic"]
OUT = ROOT / "site/assets/wall"
EDGE = 560

# What a piece is, for the search and pile demos: what it's for (cut-products.py), and its name.
NAMES = {"chair": "chair", "sofa": "sofa", "lamp": "lamp", "bed": "bed", "plant": "plant", "vase": "vase"}
# The demo rooms: their covers come from these sets.
ROOMS = {"default": "nordic", "coffee": "coffee", "signs": "signs", "travel": "travel", "documents": "documents"}
# The pile demo borrows a few pieces from the other rooms, so colours have more to sort.
PILE_EXTRAS = {"signs": [0, 3, 8, 25, 23], "coffee": [0, 6, 12], "travel": [0, 7, 18, 12]}
# Which pieces make each cover (by position in the sheet), where the first four aren't the best.
COVERS = {"default": [2, 46, 55, 13], "coffee": [0, 6, 12, 13], "signs": [0, 3, 8, 25], "travel": [2, 8, 11, 25]}


def colour(img):
    """The piece's own colour as one plain name, leaving out a white or pale ground."""
    raw = img.convert("RGB").resize((48, 48)).tobytes()
    buckets, values = {}, []
    for r, g, b in zip(raw[0::3], raw[1::3], raw[2::3]):
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if v > 0.8 and s < 0.08:
            continue
        values.append(v)
        if s < 0.18 or v < 0.18:
            continue
        deg = h * 360
        name = ("red" if deg < 14 or deg >= 340 else ("brown" if v < 0.62 else "orange") if deg < 36
                else "yellow" if deg < 55 else "green" if deg < 170 else "blue" if deg < 255 else "purple")
        buckets[name] = buckets.get(name, 0) + s * v
    name, weight = max(buckets.items(), key=lambda kv: kv[1], default=("", 0))
    if weight > 0.06 * max(len(values), 1):
        return name
    mean = sum(values) / max(len(values), 1)
    return "black" if mean < 0.38 else "white" if mean > 0.72 else "silver"


def thumb(src, dest, edge):
    """A small JPEG named with a fingerprint of its content, so browsers never show an old one."""
    img = Image.open(src)
    img.thumbnail((edge, edge))
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "JPEG", quality=74, optimize=True, progressive=True)
    data = buf.getvalue()
    named = dest.with_name(f"{dest.stem}-{hashlib.sha1(data).hexdigest()[:6]}.jpg")
    named.write_bytes(data)
    img.named = named.name
    return img


def main():
    credits = {c["file"]: {**c, "dir": src} for src in SOURCES for c in json.loads((src / "credits.json").read_text())}
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.jpg"):
        old.unlink()
    items = []
    for i, (name, credit) in enumerate(sorted(credits.items())):
        file = f"{i:02d}.jpg"
        img = thumb(credit["dir"] / name, OUT / file, EDGE)
        title = credit.get("title") or ""
        tags = [credit["kind"]] + sorted({tag for word, tag in NAMES.items() if word in title.lower()})
        items.append({"src": f"wall/{img.named}", "w": img.width, "h": img.height, "title": title,
                      "artist": credit.get("artist"), "date": credit.get("date"), "url": credit.get("url"),
                      "tags": tags, "color": colour(img)})
    (ROOT / "site/assets/wall.json").write_text(json.dumps(items, ensure_ascii=False, separators=(",", ":")))
    size = sum(f.stat().st_size for f in OUT.glob("*.jpg"))
    print(f"牆：{len(items)} 張，{size // 1024} KB")

    rooms = ROOT / "site/assets/rooms"
    rooms.mkdir(parents=True, exist_ok=True)
    for old in rooms.glob("*.jpg"):
        old.unlink()
    covers = {}
    for room, sample in ROOMS.items():
        found = json.loads((SAMPLES / sample / "credits.json").read_text())
        picks = [found[n] for n in COVERS[room]] if room in COVERS else found[:4]
        for i, c in enumerate(picks):
            covers.setdefault(room, []).append(thumb(SAMPLES / sample / c["file"], rooms / f"{room}-{i}.jpg", 320).named)
    (ROOT / "site/assets/rooms.json").write_text(json.dumps(covers))
    piles = ROOT / "site/assets/pile"
    piles.mkdir(parents=True, exist_ok=True)
    for old in piles.glob("*.jpg"):
        old.unlink()
    extras = []
    for sample, picks in PILE_EXTRAS.items():
        found = json.loads((SAMPLES / sample / "credits.json").read_text())
        for n in picks:
            file = f"{sample}-{n}.jpg"
            img = thumb(SAMPLES / sample / found[n]["file"], piles / file, 240)
            extras.append({"src": f"pile/{img.named}", "set": sample, "color": colour(img)})
    (ROOT / "site/assets/pile.json").write_text(json.dumps(extras, separators=(",", ":")))
    print(f"分堆示範：{len(extras)} 張，顏色 {sorted({e['color'] for e in extras})}")
    print(f"展室封面：{len(list(rooms.glob('*.jpg')))} 張")


if __name__ == "__main__":
    main()
