#!/usr/bin/env bash
# 把 docs/assets/menu-icon-zh.svg 渲染为输入法菜单图标使用的 PNG。
# Template 后缀让 macOS 按明/暗模式自动反相，匹配 SVG 黑底镂空设计意图。
# 仅在 SVG 设计稿改动时手动执行；产物已 commit 进 git，clone 即用。
set -euo pipefail

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "error: rsvg-convert not found. Install with: brew install librsvg" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SRC="${ROOT_DIR}/docs/assets/menu-icon-zh.svg"
DST_DIR="${ROOT_DIR}/Apps/LaplaceIME/LaplaceIME"

mkdir -p "${DST_DIR}"

rsvg-convert -w 26 -h 18 -f png -o "${DST_DIR}/MenuIconHansTemplate.png"    "${SRC}"
rsvg-convert -w 52 -h 36 -f png -o "${DST_DIR}/MenuIconHansTemplate@2x.png" "${SRC}"

echo "Wrote:"
echo "  ${DST_DIR}/MenuIconHansTemplate.png"
echo "  ${DST_DIR}/MenuIconHansTemplate@2x.png"
