#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Linguist Zixia Input - Menu Icon Generation Tool
# ------------------------------------------------------------------------------
# 概要:
#   本脚本用于将 SVG 矢量设计稿转换为符合 macOS InputMethodKit 规范的 TIFF 图标。
#
# 技术决策说明 (Architecture Decisions):
#   1. 渲染引擎: 采用 rsvg-convert (librsvg) 以确保在 16x16 / 32x32 物理像素下的边缘锐度，
#      避免系统自带 sips 引擎在矢量光格化过程中产生的次像素模糊。
#   2. 资产封装: 采用多分辨率单文件 TIFF 容器 (Multi-resolution TIFF Container)。
#      通过 tiffutil 将 1x (16px) 与 2x (32px) 资产原子化封装至单一文件，
#      以确保系统级文本服务加载过程中的资源一致性与确定性。
#   3. 构建集成: 产物直接输出至应用源码目录，利用 Xcode 文件夹同步机制自动完成 Bundle 载入。
# ------------------------------------------------------------------------------

set -euo pipefail

# 依赖校验
if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "Error: rsvg-convert (librsvg) is required for high-fidelity rendering." >&2
    exit 1
fi
if ! command -v tiffutil >/dev/null 2>&1; then
    echo "Error: tiffutil is required for atomic resource packaging." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 路径定义
SRC="${ROOT_DIR}/docs/assets/menu-icon-l-square.svg"
DST_DIR="${ROOT_DIR}/Apps/LaplaceIME/LaplaceIME"
FINAL_TIFF="${DST_DIR}/MenuIconHansTemplate.tiff"

echo "[INFO] Processing vector source: $(basename "${SRC}")"

# 1. 执行高保真光格化渲染 (临时资产)
rsvg-convert -w 16 -h 16 -f png -o "${DST_DIR}/temp_1x.png" "${SRC}"
rsvg-convert -w 32 -h 32 -f png -o "${DST_DIR}/temp_2x.png" "${SRC}"

# 2. 利用 tiffutil 执行原子化多分辨率封装
tiffutil -cathidpicheck "${DST_DIR}/temp_1x.png" "${DST_DIR}/temp_2x.png" -out "${FINAL_TIFF}"

# 3. 临时资产清理
rm "${DST_DIR}/temp_1x.png"
rm "${DST_DIR}/temp_2x.png"

echo "[SUCCESS] Atomic multi-resolution TIFF generated: ${FINAL_TIFF}"
