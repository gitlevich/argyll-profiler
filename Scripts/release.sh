#!/bin/sh
# Build, sign, notarize and package Argyll Profiler for distribution.
#
#   Scripts/release.sh                -> .build/Argyll-Profiler-<version>.dmg (notarized, stapled)
#
# One-time setup (stores an app-specific password in the keychain under the profile name):
#   xcrun notarytool store-credentials ArgyllProfiler \
#       --apple-id <your Apple ID email> --team-id YBCP8WY4VN --password <app-specific password>
# App-specific passwords: https://appleid.apple.com > Sign-In and Security > App-Specific Passwords
set -e
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-ArgyllProfiler}"
APP=".build/Argyll Profiler.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
DMG=".build/Argyll-Profiler-$VERSION.dmg"
STAGE=".build/dmg-stage"

Scripts/make-app.sh

# DMG with the app and an Applications shortcut.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Argyll Profiler.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Argyll Profiler" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')" "$DMG"

echo "submitting to Apple notary service (a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" && echo "Gatekeeper: accepted"

echo "release: $DMG"
