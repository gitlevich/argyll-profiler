#!/bin/sh
# Build, sign, notarize and package Argyll Profiler for distribution.
#
#   Scripts/release.sh                -> .build/Argyll-Profiler-<version>.dmg (notarized, stapled)
#
# Notarization credentials, one of:
#   - locally: a keychain profile (default name ArgyllProfiler), created once with
#       xcrun notarytool store-credentials ArgyllProfiler \
#           --apple-id <your Apple ID email> --team-id <TEAM ID> --password <app-specific password>
#   - CI: APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID in the environment.
# App-specific passwords: account.apple.com > Sign-In and Security > App-Specific Passwords
set -e
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-ArgyllProfiler}"
APP=".build/Argyll Profiler.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
DMG=".build/Argyll-Profiler-$VERSION.dmg"
STAGE=".build/dmg-stage"

Scripts/make-app.sh

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
[ -n "$IDENTITY" ] || { echo "no Developer ID Application certificate available" >&2; exit 1; }

# DMG with the app and an Applications shortcut.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Argyll Profiler.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Argyll Profiler" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -n "$APPLE_ID" ] && [ -n "$APPLE_APP_PASSWORD" ] && [ -n "$APPLE_TEAM_ID" ]; then
    NOTARY_AUTH="--apple-id $APPLE_ID --password $APPLE_APP_PASSWORD --team-id $APPLE_TEAM_ID"
else
    NOTARY_AUTH="--keychain-profile $PROFILE"
fi

echo "submitting to Apple notary service (a few minutes)…"
# shellcheck disable=SC2086
xcrun notarytool submit "$DMG" $NOTARY_AUTH --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" && echo "Gatekeeper: accepted"

echo "release: $DMG"
