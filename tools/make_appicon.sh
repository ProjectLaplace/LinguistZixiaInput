#!/bin/bash

# A script to generate macOS AppIcon.appiconset from an SVG or PNG master image

if [ -z "$1" ]; then
  echo "Usage: $0 <path-to-master-icon.svg-or-png>"
  exit 1
fi

INPUT_FILE="$1"
OUTPUT_DIR="Apps/LaplaceIME/LaplaceIME/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: Input file '$INPUT_FILE' not found."
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "🎨 Generating icons from $INPUT_FILE into $OUTPUT_DIR..."

# Define the sizes required for macOS App Icons
# format: "size_label real_pixel_size filename"
declare -a SIZES=(
  "16x16_1x 16 icon_16x16.png"
  "16x16_2x 32 icon_16x16@2x.png"
  "32x32_1x 32 icon_32x32.png"
  "32x32_2x 64 icon_32x32@2x.png"
  "128x128_1x 128 icon_128x128.png"
  "128x128_2x 256 icon_128x128@2x.png"
  "256x256_1x 256 icon_256x256.png"
  "256x256_2x 512 icon_256x256@2x.png"
  "512x512_1x 512 icon_512x512.png"
  "512x512_2x 1024 icon_512x512@2x.png"
)

for info in "${SIZES[@]}"; do
  set -- $info
  size_label=$1
  px=$2
  filename=$3
  echo "  -> Generating $filename (${px}x${px})"
  sips -s format png -z $px $px "$INPUT_FILE" --out "$OUTPUT_DIR/$filename" >/dev/null 2>&1
done

# Generate Contents.json
cat <<EOF > "$OUTPUT_DIR/Contents.json"
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16", "scale" : "1x", "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "size" : "16x16", "scale" : "2x", "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "1x", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "2x", "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "✅ AppIcon.appiconset generation complete!"
