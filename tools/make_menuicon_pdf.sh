#!/usr/bin/env bash
# Generate the IMK menu icon PDF from the fixed-outline SVG source.
#
# This script intentionally does not reuse make_menuicon.sh, which has carried
# several experimental TIFF/PDF paths. The source SVG must stay font-free and
# mask-free; the PDF is only a packaging format for that plain vector artwork.

set -euo pipefail

for cmd in rsvg-convert rg; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Error: ${cmd} is required." >&2
        exit 1
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# SRC="${ROOT_DIR}/docs/assets/menu-icon-zh.svg"
SRC="${ROOT_DIR}/docs/assets/menu-icon-l-square.svg"
DST="${ROOT_DIR}/Apps/LaplaceIME/LaplaceIME/MenuIconHans.pdf"

FORBIDDEN_SVG='(<text|<mask|mask=|opacity|filter|clipPath|linearGradient|radialGradient|<image)'

if rg -n "${FORBIDDEN_SVG}" "${SRC}" >/dev/null; then
    echo "Error: ${SRC} contains font, mask, transparency, filter, gradient, or raster primitives." >&2
    rg -n "${FORBIDDEN_SVG}" "${SRC}" >&2
    exit 1
fi

echo "[INFO] Rendering 22x16 pt menu icon PDF from ${SRC}"
rsvg-convert \
    -f pdf \
    --page-width=22pt \
    --page-height=16pt \
    -w 22pt \
    -h 16pt \
    -o "${DST}" \
    "${SRC}"
echo "[SUCCESS] Generated: ${DST}"
