#!/usr/bin/env python3
"""從 page.html 與 strings.json 產生六種語言的網站頁面（site/、site/zh/、site/ja/…）。

用法：python3 scripts/site/build.py
"""
import html
import json
from pathlib import Path

HERE = Path(__file__).parent
SITE = HERE.parent.parent / "site"
BASE = "https://wunder.rocavence.com/"

# 首頁依瀏覽器語言轉到對應的版本（使用者在選單選過語言就不再猜）
REDIRECT = """    var picked = null;
    try { picked = localStorage.getItem("lang"); } catch (e) {}
    if (!picked) {
      var want = (navigator.languages || [navigator.language || ""]).join(",").toLowerCase();
      var go = /zh-(hant|tw|hk|mo)/.test(want) ? "zh/" : null;
      var first = want.slice(0, 2);
      if (!go && /^(ja|ko|es|pt)$/.test(first)) go = (first === "pt" ? "pt" : first) + "/";
      if (go) location.replace(go + location.hash);
    }"""


# What fits: pictures, video, sound, PDFs, web pages, text, screenshots, any file.
KIND_ICONS = {
    "image": "M3 4.5h18v15H3zM3 15.5l5-5 4 4 3-3 6 6M15.5 9.2a1.6 1.6 0 1 0 0-.1",
    "video": "M3 5.5h13v13H3zM16 10l5-3v10l-5-3",
    "audio": "M4 10v4M7.5 7v10M11 4v16M14.5 8v8M18 10.5v3",
    "pdf": "M6 2.5h8l4.5 4.5v14.5H6zM14 2.5V7h4.5M8.8 12h6.4M8.8 15.5h6.4M8.8 19h4",
    "web": "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18M3 12h18M12 3c2.6 2.6 3.8 5.6 3.8 9s-1.2 6.4-3.8 9M12 3C9.4 5.6 8.2 8.6 8.2 12s1.2 6.4 3.8 9",
    "text": "M5 6h14M5 10h14M5 14h10M5 18h7",
    "shot": "M3 8V4h4M17 4h4v4M21 16v4h-4M7 20H3v-4M9 9h6v6H9z",
    "file": "M5.5 2.5h9l4 4v15h-13zM14.5 2.5v4h4",
}

# The wander sidebar's icons: all, for today, on this day, forgotten, trail, surprise me.
SIDE_ICONS = [
    "M2.5 2.5h4.5v4.5h-4.5zM9 2.5h4.5v4.5h-4.5zM2.5 9h4.5v4.5h-4.5zM9 9h4.5v4.5h-4.5z",
    "M8 5.2a2.8 2.8 0 1 1 0 5.6a2.8 2.8 0 1 1 0-5.6M8 1.5v1.4M8 13.1v1.4M1.5 8h1.4M13.1 8h1.4M3.4 3.4l1 1M11.6 11.6l1 1M3.4 12.6l1-1M11.6 4.4l1-1",
    "M2.5 4h11v9.5h-11zM2.5 7h11M5.5 2.2v3M10.5 2.2v3",
    "M8 2.5a5.5 5.5 0 1 1-5.2 3.7M2.5 2.5v3.6h3.6M8 5.2v3l2 1.4",
    "M4 13.5a1.6 1.6 0 1 1 0-3.2a1.6 1.6 0 1 1 0 3.2M12 5.7a1.6 1.6 0 1 1 0-3.2a1.6 1.6 0 1 1 0 3.2M5.3 11.2c3-1 2.4-4.4 5.4-5.4",
    "M2 4.5h2.5c2.5 0 4.5 7 7 7h2.5M2 11.5h2.5c1.2 0 2.2-1.5 3-3M10.5 6c.8-1 1.4-1.5 2-1.5h1.5M12.5 2.8l1.7 1.7-1.7 1.7M12.5 9.8l1.7 1.7-1.7 1.7",
]


def attr(text):
    return html.escape(text, quote=True)


def shot(page, root, name, alt, lazy=True):
    loading = ' loading="lazy"' if lazy else ""
    src = f"{root}assets/{page['shots']}{name}"
    return (f'<img class="shot-light" src="{src}-light.jpg" width="1600" height="1025"{loading} alt="{attr(alt)}">'
            f'<img class="shot-dark" src="{src}-dark.jpg" width="1600" height="1025" loading="lazy" alt="{attr(alt)}">')


def cell(value, us=False):
    """One comparison cell: Y and N become ✓ and –; prices stay plain; other notes are quiet."""
    kind = {"Y": "yes", "N": "no"}.get(value, "" if "$" in value or "<" in value else "no")
    text = {"Y": "✓", "N": "–"}.get(value, value)
    classes = " ".join(c for c in ("us" if us else "", kind) if c)
    return f'<td class="{classes}">{text}</td>' if classes else f"<td>{text}</td>"


def render(page, pages, template, wall):
    root = "../" if page["path"] else ""
    fill = {k: v for k, v in page.items() if isinstance(v, str)}
    fill["root"] = root
    fill["url"] = BASE + page["path"]
    fill["description"] = attr(page["description"])
    fill["lede_plain"] = attr(page["lede_plain"])
    fill["theme_label"] = page["theme_auto"]
    fill["h1"] = page["h1"].replace("{icon}", f'<img class="mark" src="{root}assets/mark.png" alt="" width="180" height="172">')
    fill["alternates"] = "\n".join(
        [f'<link rel="alternate" hreflang="{p["lang"]}" href="{BASE}{p["path"]}">' for p in pages]
        + [f'<link rel="alternate" hreflang="x-default" href="{BASE}">'])
    fill["redirect"] = REDIRECT if not page["path"] else ""
    fill["languages"] = "\n".join(
        f'          <li><a href="{root}{p["path"]}" hreflang="{p["lang"]}" lang="{p["lang"]}"'
        + (' aria-current="page"' if p is page else "") + f'>{p["native"]}</a></li>' for p in pages)
    fill["side_items"] = "\n".join(
        f'            <li{" class=" + chr(34) + "on" + chr(34) if i == 1 else ""}><svg viewBox="0 0 16 16"><path d="{SIDE_ICONS[i]}"/></svg>{label}</li>'
        for i, label in enumerate(page["side"]))
    fill["rooms_cards"] = room_cards(page, root)
    fill["pile_tiles"] = pile_tiles(root, wall)
    fill["piles_names"] = attr(json.dumps(page["piles_names"], ensure_ascii=False))
    fill["piles_buttons"] = "\n".join(
        f'      <button type="button" data-mode="{m}"{" class=" + chr(34) + "on" + chr(34) if i == 0 else ""}>{label}</button>'
        for i, (m, label) in enumerate(zip(["format", "kind", "theme", "color"], page["piles_modes"])))
    fill["kinds"] = "\n".join(
        f'      <li class="rise"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="{KIND_ICONS[icon]}"/></svg>'
        f'<b>{name}</b><p>{detail}</p><span>{"".join(f"<i>{c}</i>" for c in chips)}</span></li>'
        for icon, name, detail, chips in page["kinds"])
    fill["finder_queries"] = attr(json.dumps(page["finder_queries"], ensure_ascii=False))
    fill["story_steps"] = "\n".join(f"""      <article class="story-step">
        <span class="kicker">{k}</span>
        <h3>{t}</h3>
        <p>{p}</p>
        <div class="window story-inline">{shot(page, root, name, alt)}</div>
      </article>""" for k, t, p, name, alt in page["features"])
    fill["story_shots"] = "\n".join(
        f'      <div class="s-shot" data-i="{i}">{shot(page, root, f[3], f[4])}</div>' for i, f in enumerate(page["features"]))
    fill["stats"] = "\n".join(f'      <div class="stat"><b>{b}</b><span>{s}</span></div>' for b, s in page["stats"])
    # The shortcut in the first step is a key you can press on the page.
    steps = [page["steps"][0].replace("<kbd>⌘⇧C</kbd>", '<button class="collect" type="button">⌘⇧C</button>', 1)] + page["steps"][1:]
    fill["steps"] = "\n".join(f"      <li>{s}</li>" for s in steps)
    fill["gets"] = "\n".join(f"      <li>{g}</li>" for g in page["gets"])
    fill["compare"] = "\n".join(f"        <tr><td>{label}</td>{cell(us, us=True)}{cell(atlas)}{cell(eagle)}</tr>"
                                for label, us, atlas, eagle in page["compare"])
    fill["faq"] = "\n".join(
        f'    <details{" id=" + chr(34) + item[2] + chr(34) if len(item) > 2 else ""}>\n'
        f"      <summary>{item[0]}</summary>\n      {item[1]}\n    </details>" for item in page["faq"])
    out = template
    for key, value in fill.items():
        out = out.replace("{{" + key + "}}", value)
    assert "{{" not in out, out[out.index("{{"):out.index("{{") + 40]
    return out


# The demo rooms: cover pictures (site/assets/rooms/, from scripts/site/wall.py), count, synced.
ROOMS = [("default", 30, False), ("coffee", 126, False), ("signs", 74, True), ("travel", 57, False), ("documents", 89, True)]


def room_cards(page, root):
    cards = []
    for i, ((key, count, cloud), name) in enumerate(zip(ROOMS, page["rooms"])):
        mosaic = "".join(f'<img src="{root}assets/rooms/{key}-{n}.jpg" alt="" loading="lazy">' for n in range(4))
        badges = (f'<em class="now">{page["rooms_current"]}</em>' if i == 0 else "") + ("<em>iCloud</em>" if cloud else "")
        cards.append(f'      <li class="rise{" on" if i == 0 else ""}"><div class="cover">{mosaic}<span>{badges}</span></div>'
                     f'<b>{name}</b><small>{page["rooms_count"].replace("{n}", str(count))}</small></li>')
    return "\n".join(cards)


# The pile demo: the same things, piled four ways. Pictures come from the wall;
# a few quotes, pages and PDFs show that piles are about more than pictures.
PILE_CARDS = [
    ("text", "book", "quote", "white", "“Less, but better.”"),
    ("text", "book", "quote", "white", "“Good design is honest.”"),
    ("text", "book", "quote", "white", "“As little design as possible.”"),
    ("web", "place", "audio", "silver", "vitsoe.com"),
    ("web", "book", "kitchen", "silver", "wikipedia.org/Bauhaus"),
    ("web", "place", "clock", "silver", "designmuseum.org"),
    ("pdf", "book", "desk", "white", "ten-principles.pdf"),
    ("pdf", "book", "audio", "white", "catalogue-1965.pdf"),
]
PILE_PICKS = [("audio", 4), ("clock", 3), ("kitchen", 3), ("care", 1), ("desk", 2), ("light", 1)]
EXTRA_KIND = {"signs": "sign", "coffee": "coffee", "travel": "travel"}


def pile_tiles(root, wall):
    tiles, used = [], set()
    for theme, want in PILE_PICKS:
        for w in [w for w in wall if theme in w["tags"] and w["src"] not in used][:want]:
            used.add(w["src"])
            tiles.append(f'<div class="pt" data-format="image" data-kind="product" data-theme="{theme}" data-color="{w["color"]}">'
                         f'<img src="{root}assets/{w["src"]}" alt="" loading="lazy"></div>')
    for e in json.loads((SITE / "assets/pile.json").read_text()):
        kind = EXTRA_KIND[e["set"]]
        tiles.append(f'<div class="pt" data-format="image" data-kind="{kind}" data-theme="{kind}" data-color="{e["color"]}">'
                     f'<img src="{root}assets/{e["src"]}" alt="" loading="lazy"></div>')
    for fmt, kind, theme, color, text in PILE_CARDS:
        tiles.append(f'<div class="pt card {fmt}" data-format="{fmt}" data-kind="{kind}" data-theme="{theme}" data-color="{color}">'
                     f'<span>{html.escape(text)}</span></div>')
    return "\n".join("      " + t for t in tiles)


def main():
    template = (HERE / "page.html").read_text()
    wall = json.loads((SITE / "assets/wall.json").read_text())
    pages = list(json.loads((HERE / "strings.json").read_text()).values())
    for page in pages:
        folder = SITE / page["path"]
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "index.html").write_text(render(page, pages, template, wall))
        print(f"{page['lang']:6} → site/{page['path']}index.html")


if __name__ == "__main__":
    main()
