#!/usr/bin/env bash
# Generate the square floating indicator bitmap used by LaplaceIndicator.
#
# The IMK menu icon keeps its PDF pipeline because macOS consumes it through
# plist icon keys. The floating indicator is our own NSPanel, so it uses a
# multi-representation TIFF generated from the original square SVG design.

set -euo pipefail

for cmd in rsvg-convert rg tiffutil; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Error: ${cmd} is required." >&2
        exit 1
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${ROOT_DIR}/docs/assets/indicator-icon-l-square.svg"
DST="${ROOT_DIR}/Apps/LaplaceIME/LaplaceIME/LaplaceIndicatorIcon.tiff"
TMP_SVG="$(mktemp "${TMPDIR:-/tmp}/laplace-indicator-icon.XXXXXX.svg")"
PNG_1X="$(mktemp "${TMPDIR:-/tmp}/laplace-indicator-icon.1x.XXXXXX.png")"
PNG_2X="$(mktemp "${TMPDIR:-/tmp}/laplace-indicator-icon.2x.XXXXXX.png")"
trap 'rm -f "${TMP_SVG}" "${PNG_1X}" "${PNG_2X}"' EXIT

FORBIDDEN_SVG='(<text|opacity|filter|clipPath|linearGradient|radialGradient|<image)'

if rg -n "${FORBIDDEN_SVG}" "${SRC}" >/dev/null; then
    echo "Error: ${SRC} contains font, transparency, filter, gradient, or raster primitives." >&2
    rg -n "${FORBIDDEN_SVG}" "${SRC}" >&2
    exit 1
fi

# The source asset is a template image: a black square badge with transparent
# knockout strokes. The floating indicator wants the inverse visual treatment
# on the same geometry: panel-matched light background with dark foreground
# strokes. Keep the source geometry as the single source of truth and only
# rewrite the template colors/structure for this runtime bitmap.
sed \
    -e '/<defs>/d' \
    -e '/<mask id="knockout">/d' \
    -e '/<\/mask>/d' \
    -e '/<\/defs>/d' \
    -e '/mask="url(#knockout)"/d' \
    -e 's/fill="white"/fill="#EBEBEB"/g' \
    -e 's/stroke="black"/stroke="#444444"/g' \
    "${SRC}" >"${TMP_SVG}"

echo "[INFO] Rendering 22x22 and 44x44 px indicator icon PNG representations"
rsvg-convert \
    -f png \
    -w 22 \
    -h 22 \
    -o "${PNG_1X}" \
    "${TMP_SVG}"
rsvg-convert \
    -f png \
    -w 44 \
    -h 44 \
    -o "${PNG_2X}" \
    "${TMP_SVG}"

echo "[INFO] Combining PNG representations into TIFF"
tiffutil -cathidpicheck "${PNG_1X}" "${PNG_2X}" -out "${DST}"
echo "[SUCCESS] Generated: ${DST}"
