#!/bin/bash
# Builds LocalDrop for Mac in Release, installs it to /Applications and starts it.
#
#   DEVELOPMENT_TEAM=<your team ID> macos/scripts/install.sh
#
# Sign with your team every time: the Keychain lets the same signature reuse LocalDrop's device
# key, while an ad-hoc signature changes with every build and macOS asks for access again.
# With a Developer ID certificate (paid membership) the build is signed like the released DMG,
# so macOS keeps Bluetooth and Downloads permissions when switching between the two.
set -euo pipefail

team="${DEVELOPMENT_TEAM:-${1:-}}"
if [[ -z "$team" ]]; then
    echo "Set DEVELOPMENT_TEAM to your Apple team ID (Xcode › Settings › Accounts)." >&2
    exit 1
fi

identity="Apple Development"
if security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($team)"; then
    identity="Developer ID Application"
fi

cd "$(dirname "$0")/.."
xcodebuild -project LocalDrop.xcodeproj -scheme LocalDrop -configuration Release -derivedDataPath build \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
    -destination "generic/platform=macOS" -quiet build

# Quit any running copy first (including one started from Xcode), so the new one takes over
# Bluetooth, the network port and the menu bar icon.
osascript -e 'tell application id "dev.localdrop.mac" to quit' 2>/dev/null || true
for _ in {1..20}; do
    pgrep -f "/Contents/MacOS/LocalDrop$" >/dev/null || break
    sleep 0.5
done

# Installed under the name people see, "Dewlet"; copies under the old names go.
installed="/Applications/Dewlet.app"
rm -rf /Applications/LocalDrop.app "/Applications/Local Drop.app" "$installed"
cp -R build/Build/Products/Release/LocalDrop.app "$installed"

# The Share extension must come from the installed copy: forget the ones in build products,
# or macOS may run the extension (and start the app) from there.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for product in build/Build/Products/*/LocalDrop.app; do
    pluginkit -r "$product/Contents/PlugIns/LocalDropShare.appex" 2>/dev/null || true
    "$lsregister" -u "$product" 2>/dev/null || true
done
"$lsregister" -f "$installed"
pluginkit -a "$installed/Contents/PlugIns/LocalDropShare.appex"
pkill -x LocalDropShare 2>/dev/null || true

open "$installed"
echo "Installed $installed"
