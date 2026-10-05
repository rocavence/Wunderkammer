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


def render(page, pages, template):
    root = "../" if page["path"] else ""
    fill = {k: v for k, v in page.items() if isinstance(v, str)}
    fill["root"] = root
    fill["url"] = BASE + page["path"]
    fill["description"] = attr(page["description"])
    fill["lede_plain"] = attr(page["lede_plain"])
    fill["theme_label"] = page["theme_auto"]
    fill["h1"] = page["h1"].replace("{icon}", f'<img src="{root}assets/icon.png" alt="" width="96" height="96">')
    fill["alternates"] = "\n".join(
        [f'<link rel="alternate" hreflang="{p["lang"]}" href="{BASE}{p["path"]}">' for p in pages]
        + [f'<link rel="alternate" hreflang="x-default" href="{BASE}">'])
    fill["redirect"] = REDIRECT if not page["path"] else ""
    fill["languages"] = "\n".join(
        f'          <li><a href="{root}{p["path"]}" hreflang="{p["lang"]}" lang="{p["lang"]}"'
        + (' aria-current="page"' if p is page else "") + f'>{p["native"]}</a></li>' for p in pages)
    fill["shot_collection"] = shot(page, root, "collection", page["alt_collection"], lazy=False)
    fill["stats"] = "\n".join(f'      <div class="stat"><b>{b}</b><span>{s}</span></div>' for b, s in page["stats"])
    fill["steps"] = "\n".join(f"      <li>{s}</li>" for s in page["steps"])
    fill["gets"] = "\n".join(f"      <li>{g}</li>" for g in page["gets"])
    fill["features"] = "\n".join(f"""    <article class="feature rise">
      <header>
        <span class="kicker">{k}</span>
        <h3>{t}</h3>
        <p>{p}</p>
      </header>
      <div class="window">{shot(page, root, name, alt)}</div>
    </article>""" for k, t, p, name, alt in page["features"])
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


def main():
    template = (HERE / "page.html").read_text()
    pages = list(json.loads((HERE / "strings.json").read_text()).values())
    for page in pages:
        folder = SITE / page["path"]
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "index.html").write_text(render(page, pages, template))
        print(f"{page['lang']:6} → site/{page['path']}index.html")


if __name__ == "__main__":
    main()
