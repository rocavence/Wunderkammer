#!/usr/bin/env python3
"""從 Iconoir 的 SVG 產生 Xcode Asset Catalog 與 Swift enum。

用法：python3 scripts/reicon/generate.py
icon 清單在 scripts/reicon/icons.txt：每行「程式裡的名字 Iconoir 檔名」。
Iconoir 的 SVG 放在 .cache/iconoir/icons（npm pack iconoir 解開後的 package/icons）。
"""

import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ICONOIR_VERSION = "7.12.1"

ROOT = Path(__file__).resolve().parents[2]
ICON_LIST = ROOT / "scripts/reicon/icons.txt"
SOURCE = ROOT / ".cache/iconoir/icons"
CATALOG = ROOT / "Wunderkammer/Resources/Assets.xcassets/Reicon"
SWIFT_OUT = ROOT / "Wunderkammer/DesignSystem/Icons/Reicon+Generated.swift"
# Iconoir 沒有的 icon，照它的格線與筆畫自己畫（例如 robot）
CUSTOM = ROOT / "scripts/reicon/custom"

# 線條粗細：Iconoir 預設 1.5，介面要粗一點
STROKE = 2.3
SWIFT_KEYWORDS = {"repeat", "default", "case", "in", "is", "as", "return", "self", "func", "var", "let"}


def ensure_source() -> None:
    if SOURCE.exists():
        return
    print(f"下載 iconoir@{ICONOIR_VERSION}")
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["npm", "pack", f"iconoir@{ICONOIR_VERSION}"], cwd=tmp, check=True, capture_output=True)
        subprocess.run(["tar", "xzf", f"iconoir-{ICONOIR_VERSION}.tgz"], cwd=tmp, check=True)
        SOURCE.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(Path(tmp) / "package/icons", SOURCE)


def load_list() -> list[tuple[str, str]]:
    pairs = []
    for line in ICON_LIST.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, source = line.split()
        pairs.append((name, source))
    return pairs


def prepare(svg: str) -> str:
    # CoreSVG 不支援 currentColor；template image 只看 alpha，顏色固定黑色即可
    svg = svg.replace("currentColor", "#000000")
    # 自己畫的眼睛這類點要比線粗，標了 stroke-width="2.6" 的照比例放大
    svg = svg.replace('stroke-width="2.6"', f'stroke-width="{STROKE * 1.7:.1f}" data-keep="1"')
    return re.sub(r'stroke-width="[\d.]+"(?! data-keep)', f'stroke-width="{STROKE}"', svg)


def write_json(path: Path, obj: dict) -> None:
    path.write_text(json.dumps(obj, indent=2) + "\n")


def swift_case(name: str) -> str:
    head, *rest = name.split("-")
    ident = head + "".join(p.capitalize() for p in rest)
    return f"`{ident}`" if ident in SWIFT_KEYWORDS else ident


def main() -> int:
    ensure_source()
    pairs = load_list()
    missing = [s for _, s in pairs if not (SOURCE / "regular" / f"{s}.svg").exists() and not (CUSTOM / f"{s}.svg").exists()]
    if missing:
        print(f"Iconoir 沒有這些 icon：{', '.join(missing)}", file=sys.stderr)
        return 1

    if CATALOG.exists():
        shutil.rmtree(CATALOG)
    CATALOG.mkdir(parents=True)
    write_json(CATALOG / "Contents.json", {
        "info": {"author": "xcode", "version": 1},
        "properties": {"provides-namespace": True},
    })

    for name, source in pairs:
        custom = CUSTOM / f"{source}.svg"
        solid = SOURCE / "solid" / f"{source}.svg"
        regular = custom if custom.exists() else SOURCE / "regular" / f"{source}.svg"
        files = {"outline": regular, "filled": solid if solid.exists() and not custom.exists() else regular}
        for suffix, path in files.items():
            imageset = CATALOG / f"{name}.{suffix}.imageset"
            imageset.mkdir()
            (imageset / f"{name}.{suffix}.svg").write_text(prepare(path.read_text()))
            write_json(imageset / "Contents.json", {
                "images": [{"filename": f"{name}.{suffix}.svg", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
                "properties": {
                    "preserves-vector-representation": True,
                    "template-rendering-intent": "template",
                },
            })

    cases = "\n".join(f'    case {swift_case(n)} = "{n}"' for n, _ in pairs)
    SWIFT_OUT.parent.mkdir(parents=True, exist_ok=True)
    SWIFT_OUT.write_text(
        "// 由 scripts/reicon/generate.py 產生，請勿手動修改\n"
        f"// Iconoir {ICONOIR_VERSION}\n\n"
        "enum Reicon: String, CaseIterable, Sendable {\n"
        f"{cases}\n"
        "}\n"
    )
    print(f"產生 {len(pairs)} 個 icon（Iconoir {ICONOIR_VERSION}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
