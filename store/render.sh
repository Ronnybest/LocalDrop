#!/bin/bash
# Renders the Play Store graphics from their sources with headless Chrome:
# icon.svg → icon.png (512×512), feature-graphic.html → feature-graphic.png (1024×500).
set -euo pipefail
cd "$(dirname "$0")"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
render() { "$chrome" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size="$2" --screenshot="$PWD/$3" "file://$PWD/$1" 2>/dev/null; }
render icon.svg 512,512 icon.png
render feature-graphic.html 1024,500 feature-graphic.png
sips -g pixelWidth -g pixelHeight icon.png feature-graphic.png | grep pixel
