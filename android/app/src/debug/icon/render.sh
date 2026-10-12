#!/bin/bash
# Renders the debug launcher foreground from its SVG into the densities Android picks from.
set -euo pipefail
cd "$(dirname "$0")"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
tmp=$(mktemp -d)
"$chrome" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size=432,432 \
    --screenshot="$tmp/full.png" "file://$PWD/ic_launcher_foreground_debug.svg" 2>/dev/null
for pair in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
    density=${pair%%:*}; size=${pair##*:}
    mkdir -p "../res/drawable-$density"
    sips -z "$size" "$size" "$tmp/full.png" --out "../res/drawable-$density/ic_launcher_foreground_debug.png" >/dev/null
done
rm -rf "$tmp"
