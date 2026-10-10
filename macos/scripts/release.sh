#!/bin/bash
# Builds LocalDrop for Mac for people outside development: signed with Developer ID, notarized
# by Apple, in a DMG to drag into Applications. The result is build/release/LocalDrop-<version>.dmg.
#
#   DEVELOPMENT_TEAM=<your team ID> macos/scripts/release.sh
#
# Needs, once, in your own Keychain (nothing secret goes through this script):
#   - a "Developer ID Application" certificate: Xcode › Settings › Accounts › Manage Certificates;
#   - notary credentials saved under the profile name below:
#       xcrun notarytool store-credentials localdrop-notary --apple-id <Apple ID> --team-id <team ID>
set -euo pipefail

team="${DEVELOPMENT_TEAM:-${1:-}}"
if [[ -z "$team" ]]; then
    echo "Set DEVELOPMENT_TEAM to your Apple team ID." >&2
    exit 1
fi
profile="${NOTARY_PROFILE:-localdrop-notary}"

cd "$(dirname "$0")/.."
out=build/release
rm -rf "$out"
mkdir -p "$out"

# Archive, then export for Developer ID: Xcode signs the app and its Share extension with the
# Developer ID certificate, with the hardened runtime notarization requires.
xcodebuild -project LocalDrop.xcodeproj -scheme LocalDrop -configuration Release \
    -archivePath "$out/LocalDrop.xcarchive" -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -quiet archive

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$team</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$out/LocalDrop.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates -quiet

app="$out/export/LocalDrop.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
codesign --verify --deep --strict "$app"

# The app is notarized and stapled on its own, so a copy taken out of the DMG opens offline too.
echo "Notarizing the app…"
ditto -c -k --keepParent "$app" "$out/LocalDrop.zip"
xcrun notarytool submit "$out/LocalDrop.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
rm "$out/LocalDrop.zip"

# The DMG: the app under the name people see, and a link to Applications to drag it onto.
dmg="$out/LocalDrop-$version.dmg"
stage="$out/dmg"
mkdir -p "$stage"
ditto "$app" "$stage/Local Drop.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Local Drop" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" -quiet
rm -rf "$stage"
identity=$(security find-identity -v -p codesigning | grep -o "\"Developer ID Application: [^\"]*($team)\"" | head -1 | tr -d '"')
codesign --sign "$identity" --timestamp "$dmg"

echo "Notarizing the DMG…"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"

spctl --assess --type open --context context:primary-signature --verbose "$dmg"
spctl --assess --type execute --verbose "$app"
echo "Built $dmg"
