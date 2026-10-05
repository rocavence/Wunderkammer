#!/usr/bin/env python3
"""App icon: the stacked arch cards on a cream tile (macOS icon grid).

用法：python3 scripts/icon/make-icon.py <輸出的 1024 PNG>
主體來自 scripts/icon/cards-1024.png（cards-source.png 去白底後的版本）。
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

CREAM = (0xFA, 0xF6, 0xF0, 255)  # #FAF6F0, the site's ground too
SIDE, BODY, RADIUS = 1024, (100, 100, 924, 924), 185
FILL = 0.78  # 主體佔底板的比例
RAISE = 0.02  # 主體往上移，佔底板高度的比例

out = sys.argv[1]
def without_shadow(art):
    """Only the cards: the soft shadow kept from the cut-out goes, the edges stay smooth."""
    solid = art.getchannel("A").point(lambda v: 255 if v > 200 else 0).filter(ImageFilter.MaxFilter(5))
    alpha = Image.composite(art.getchannel("A"), Image.new("L", art.size, 0), solid)
    art.putalpha(alpha)
    return art


art = without_shadow(Image.open("scripts/icon/cards-1024.png").convert("RGBA"))
art = art.crop(art.getchannel("A").point(lambda v: 255 if v > 200 else 0).getbbox())
scale = FILL * (BODY[2] - BODY[0]) / max(art.size)
art = art.resize((round(art.size[0] * scale), round(art.size[1] * scale)), Image.LANCZOS)

canvas = Image.new("RGBA", (SIDE, SIDE), (0, 0, 0, 0))
shade = Image.new("L", (SIDE, SIDE), 0)
ImageDraw.Draw(shade).rounded_rectangle((BODY[0], BODY[1] + 14, BODY[2], BODY[3] + 14), RADIUS, fill=70)
canvas.paste(Image.new("RGBA", (SIDE, SIDE), (0, 0, 0, 255)), (0, 0), shade.filter(ImageFilter.GaussianBlur(17)))

tile = Image.new("RGBA", (SIDE, SIDE), CREAM)
ox, oy = (SIDE - art.size[0]) // 2, (SIDE - art.size[1]) // 2 - round(RAISE * (BODY[3] - BODY[1]))
tile.alpha_composite(art, (ox, oy))

mask = Image.new("L", (SIDE, SIDE), 0)
ImageDraw.Draw(mask).rounded_rectangle(BODY, RADIUS, fill=255)
canvas.paste(tile, (0, 0), mask)
ImageDraw.Draw(canvas).rounded_rectangle(BODY, RADIUS, outline=(0, 0, 0, 20), width=2)
canvas.save(out)
