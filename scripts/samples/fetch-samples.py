#!/usr/bin/env python3
"""下載芝加哥藝術博物館（Art Institute of Chicago）的公有領域圖片（CC0），當作截圖與網站用的示範收藏。

用法：scripts/samples/fetch-samples.py [輸出資料夾]   預設 build/samples/aic
每個主題取幾件有圖的作品，檔名用作品名稱，另存 credits.json 記下出處。
"""
import json
import re
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

API = "https://api.artic.edu/api/v1/artworks/search"
IIIF = "https://www.artic.edu/iiif/2/{}/full/843,/0/default.jpg"
THEMES = {
    "butterfly": 5, "shell": 4, "botanical": 5, "bird": 5, "map": 3, "beetle": 2,
    "fan": 2, "astronomy": 2, "mask": 2, "teapot": 3, "fish": 3, "moon": 3, "vase": 3, "insect": 2,
}


def get(url):
    return subprocess.run(["curl", "-fsSL", "--max-time", "60", "-A", "Wunder sample fetcher", url],
                          check=True, capture_output=True).stdout


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/samples/aic")
    out.mkdir(parents=True, exist_ok=True)
    credits, seen = [], set()
    for theme, want in THEMES.items():
        q = urllib.parse.urlencode({
            "q": theme, "limit": 30, "fields": "id,title,image_id,artist_title,date_display,is_public_domain",
            "query[term][is_public_domain]": "true",
        })
        hits = json.loads(get(f"{API}?{q}")).get("data") or []
        got = 0
        for art in hits:
            if got >= want:
                break
            if not art.get("is_public_domain") or not art.get("image_id") or art["id"] in seen:
                continue
            title = re.sub(r'[\\/:*?"<>|]', "", art.get("title") or theme).strip()[:60] or theme
            path = out / f"{title}.jpg"
            if path.exists():
                path = out / f"{title} ({art['id']}).jpg"
            try:
                path.write_bytes(get(IIIF.format(art["image_id"])))
            except subprocess.CalledProcessError:
                continue
            seen.add(art["id"])
            credits.append({"file": path.name, "title": art.get("title"), "artist": art.get("artist_title"),
                            "date": art.get("date_display"), "url": f"https://www.artic.edu/artworks/{art['id']}",
                            "license": "CC0"})
            got += 1
            time.sleep(0.2)
        print(f"{theme}: {got}")
    (out / "credits.json").write_text(json.dumps(credits, ensure_ascii=False, indent=2))
    print(f"完成：{len(credits)} 件，{out}")


if __name__ == "__main__":
    main()
