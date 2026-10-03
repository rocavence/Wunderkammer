#!/bin/zsh
# 下載並編譯語意搜尋用的 MobileCLIP S0（Apple，約 120 MB）與 CLIP 分詞表。
# 用法：scripts/models/fetch-mobileclip.sh   安裝到 ~/Library/Application Support/Wunderkammer/models
set -euo pipefail

DEST="$HOME/Library/Application Support/Wunderkammer/models"
HF=https://huggingface.co/apple/coreml-mobileclip/resolve/main
WORK=$(mktemp -d)
mkdir -p "$DEST"

for part in image text; do
  pkg="$WORK/mobileclip_s0_$part.mlpackage"
  for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    mkdir -p "$pkg/$(dirname $f)"
    curl -fsSL -o "$pkg/$f" "$HF/mobileclip_s0_$part.mlpackage/$f"
  done
  xcrun coremlcompiler compile "$pkg" "$DEST" >/dev/null
done
curl -fsSL https://github.com/openai/CLIP/raw/main/clip/bpe_simple_vocab_16e6.txt.gz | gunzip > "$DEST/bpe_simple_vocab_16e6.txt"
rm -rf "$WORK"
echo "完成：$DEST"
