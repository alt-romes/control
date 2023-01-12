#!/usr/local/bin/bash

output_path=/tmp/output.iconset
mkdir -p "$output_path"

# the convert command comes from imagemagick
for size in 16 32 64 128 256; do
  half="$(($size / 2))"
  convert $1 -resize x$size $output_path/icon_${size}x${size}.png
  convert $1 -resize x$size $output_path/icon_${half}x${half}@2x.png
done

iconutil -c icns $output_path
