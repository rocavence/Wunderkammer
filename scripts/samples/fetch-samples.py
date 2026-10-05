#!/usr/bin/env python3
"""下載克里夫蘭美術館（Cleveland Museum of Art）Open Access 的公有領域圖片（CC0），當作截圖與網站用的示範收藏。

用法：scripts/samples/fetch-samples.py [組名…]   預設下載全部組，存到 build/samples/<組名>/
每組依關鍵字取幾件有圖的作品，檔名用作品名稱，另存 credits.json 記下出處。
只取館方標為 CC0 的作品。
"""
import json
import re
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

API = "https://openaccess-api.clevelandart.org/api/artworks/"
SETS = {
    # 網站與截圖的主要圖組：現代主義、包浩斯前後的抽象與設計（1890 年以後）
    "modern": {"abstraction": 8, "geometric": 6, "Delaunay": 4, "Klee": 5, "Mondrian": 3, "Lalique": 5,
               "Tiffany": 4, "cubist": 3, "Gris": 2, "Art Deco": 3, "Schlemmer": 1, "Kandinsky": 1,
               "Modigliani": 1, "poster": 3, "Puiforcat": 2, "Steuben": 2, "chair": 2, "Wiener": 2},
    "coffee": {"coffee pot": 3, "coffee": 3, "teapot": 2, "cup and saucer": 2},
    "documents": {"manuscript": 3, "letter": 2, "book": 2, "calligraphy": 2},
    # 舊的示範收藏（app 截圖仍在用）
    "cma": {"butterfly": 5, "shell": 4, "botanical": 5, "bird": 5, "map": 3, "beetle": 2, "fan": 2,
            "astronomy": 2, "mask": 2, "teapot": 3, "fish": 3, "moon": 3, "vase": 3, "insect": 2},
}


def get(url):
    return subprocess.run(["curl", "-fsSL", "--max-time", "60", "-A", "Wunder sample fetcher", url],
                          check=True, capture_output=True).stdout


SINCE = {"modern": 1890}


def fetch(name, themes):
    out = Path("build/samples") / name
    out.mkdir(parents=True, exist_ok=True)
    credits, seen = [], set()
    for theme, want in themes.items():
        params = {"q": theme, "cc0": 1, "has_image": 1, "limit": 40}
        if name in SINCE:
            params["created_after"] = SINCE[name]
        q = urllib.parse.urlencode(params)
        hits = json.loads(get(f"{API}?{q}")).get("data") or []
        got = 0
        for art in hits:
            if got >= want:
                break
            image = ((art.get("images") or {}).get("web") or {}).get("url")
            if not image or art["id"] in seen or art.get("share_license_status") not in (None, "CC0"):
                continue
            title = re.sub(r'[\\/:*?"<>|]', "", art.get("title") or theme).strip()[:60] or theme
            path = out / f"{title}.jpg"
            if path.exists():
                path = out / f"{title} ({art['id']}).jpg"
            try:
                path.write_bytes(get(image))
            except subprocess.CalledProcessError:
                continue
            seen.add(art["id"])
            creators = ", ".join(c.get("description", "") for c in art.get("creators") or [])
            credits.append({"file": path.name, "title": art.get("title"), "artist": creators or None,
                            "date": art.get("creation_date"), "url": art.get("url"), "license": "CC0",
                            "theme": theme, "type": art.get("type")})
            got += 1
            time.sleep(0.1)
    (out / "credits.json").write_text(json.dumps(credits, ensure_ascii=False, indent=2))
    print(f"{name}: {len(credits)} 件")


def main():
    for name in sys.argv[1:] or SETS:
        fetch(name, SETS[name])


if __name__ == "__main__":
    main()
