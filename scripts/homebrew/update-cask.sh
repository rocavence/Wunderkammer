#!/bin/zsh
# 把 Homebrew tap（rocavence/homebrew-tap）的 wunder cask 更新成某個 Release 的版本與 SHA-256。
# 用法：scripts/homebrew/update-cask.sh 0.5.5   發版（gh release create）之後執行
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION="${1:?版本號，例如 0.5.5}"
SHA=$(gh release download "v$VERSION" -p Wunder.zip.sha256 -O - | cut -d' ' -f1)
BODY=$(sed -e "s/{{version}}/$VERSION/" -e "s/{{sha256}}/$SHA/" scripts/homebrew/wunder.rb.template | base64)
OLD=$(gh api repos/rocavence/homebrew-tap/contents/Casks/wunder.rb -q .sha 2>/dev/null || true)
EXTRA=()
[[ -n "$OLD" ]] && EXTRA=(-f "sha=$OLD")
gh api -X PUT repos/rocavence/homebrew-tap/contents/Casks/wunder.rb \
  -f message="wunder $VERSION" -f content="$BODY" "${EXTRA[@]}" -q .commit.sha
echo "Homebrew：wunder $VERSION（$SHA）"
