#!/bin/bash
# Builds Dewlet for the Mac App Store: archived, then exported signed for App Store Connect.
# The result is build/appstore/export/Dewlet.pkg, to upload with Transporter; with UPLOAD=1
# Xcode uploads it itself, with the Apple ID signed in under Xcode › Settings › Accounts.
#
#   DEVELOPMENT_TEAM=<your team ID> macos/scripts/appstore.sh
#   UPLOAD=1 DEVELOPMENT_TEAM=<your team ID> macos/scripts/appstore.sh
#
# Needs the app's record in App Store Connect (bundle id com.zepponapps.localdrop.mac). Xcode
# creates the Apple Distribution and Mac Installer Distribution certificates and the App Store
# profiles itself (automatic signing). Raise CURRENT_PROJECT_VERSION before every upload:
# App Store Connect takes each build number only once.
set -euo pipefail

team="${DEVELOPMENT_TEAM:-${1:-}}"
if [[ -z "$team" ]]; then
    echo "Set DEVELOPMENT_TEAM to your Apple team ID." >&2
    exit 1
fi
destination=export
[[ "${UPLOAD:-}" == 1 ]] && destination=upload

cd "$(dirname "$0")/.."
out=build/appstore
rm -rf "$out"
mkdir -p "$out"

# The same archive as release.sh: signed for development, one identity for both targets; the
# export re-signs it for the App Store.
xcodebuild -project LocalDrop.xcodeproj -scheme LocalDrop -configuration Release \
    -archivePath "$out/LocalDrop.xcarchive" -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    PROVISIONING_PROFILE_SPECIFIER= -allowProvisioningUpdates -quiet archive

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$destination</string>
    <key>teamID</key>
    <string>$team</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/LocalDrop.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates -quiet

version=$(/usr/libexec/PlistBuddy -c "Print ApplicationProperties:CFBundleShortVersionString" "$out/LocalDrop.xcarchive/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print ApplicationProperties:CFBundleVersion" "$out/LocalDrop.xcarchive/Info.plist")
if [[ "$destination" == upload ]]; then
    echo "Uploaded $version ($build) to App Store Connect"
else
    echo "Built $out/export/Dewlet.pkg — $version ($build); upload it with Transporter"
fi
