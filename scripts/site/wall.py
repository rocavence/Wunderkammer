#!/usr/bin/env python3
"""網站收藏牆的素材：把示範收藏（scripts/samples/fetch-samples.py 下載的 CC0 圖片）縮成小圖，
寫出 site/assets/wall.json（尺寸、標題、作者、搜尋示範用的標籤與主色）。

用法：python3 scripts/site/wall.py
"""
import colorsys
import json
import re
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).parent.parent.parent
SRC = ROOT / "build/samples/cma"
OUT = ROOT / "site/assets/wall"
EDGE = 560

# What a title says it is, for the search demo.
WORDS = {
    "butterfly": ["butterfly"], "bird": ["bird", "pheasant", "eagle", "flycatcher", "crane"],
    "fish": ["fish"], "moon": ["moon"], "shell": ["shell", "conch"], "vase": ["vase", "vessel", "bottle", "amphora"],
    "teapot": ["teapot"], "mask": ["mask"], "map": ["map", "pianta"], "insect": ["insect", "beetle", "ladybird"],
    "flower": ["flower", "botanical", "begonia", "orchid", "susuki"],
}


def colour(img):
    """The strongest colour in the picture, as one plain name."""
    raw = img.convert("RGB").resize((48, 48)).tobytes()
    best, score = "gray", 0.0
    buckets = {}
    for r, g, b in zip(raw[0::3], raw[1::3], raw[2::3]):
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if s < 0.28 or v < 0.25:
            continue
        deg = h * 360
        name = ("red" if deg < 18 or deg >= 340 else "orange" if deg < 45 else "gold" if deg < 65
                else "green" if deg < 170 else "blue" if deg < 255 else "purple")
        buckets[name] = buckets.get(name, 0) + s * v
    for name, weight in buckets.items():
        if weight > score:
            best, score = name, weight
    return best if score > 60 else "gray"


def main():
    credits = {c["file"]: c for c in json.loads((SRC / "credits.json").read_text())}
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.jpg"):
        old.unlink()
    items = []
    for i, (name, credit) in enumerate(sorted(credits.items())):
        img = Image.open(SRC / name)
        img.thumbnail((EDGE, EDGE))
        file = f"{i:02d}.jpg"
        img.convert("RGB").save(OUT / file, quality=74, optimize=True, progressive=True)
        title = credit.get("title") or ""
        tags = [tag for tag, words in WORDS.items() if any(re.search(rf"\b{w}", title.lower()) for w in words)]
        items.append({"src": f"wall/{file}", "w": img.width, "h": img.height, "title": title,
                      "artist": credit.get("artist"), "date": credit.get("date"), "url": credit.get("url"),
                      "tags": tags, "color": colour(img)})
    (ROOT / "site/assets/wall.json").write_text(json.dumps(items, ensure_ascii=False, separators=(",", ":")))
    size = sum(f.stat().st_size for f in OUT.glob("*.jpg"))
    print(f"{len(items)} 張，{size // 1024} KB")


if __name__ == "__main__":
    main()
