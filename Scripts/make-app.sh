#!/bin/sh
# Builds the SwiftUI app target and wraps it in a runnable .app bundle at .build/Argyll Profiler.app
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG" --product ArgyllApp

APP=".build/Argyll Profiler.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/ArgyllApp" "$APP/Contents/MacOS/ArgyllApp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Argyll Profiler</string>
    <key>CFBundleDisplayName</key>     <string>Argyll Profiler</string>
    <key>CFBundleIdentifier</key>      <string>com.vlad.argyll-profiler</string>
    <key>CFBundleExecutable</key>      <string>ArgyllApp</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs it locally; no sandbox, Argyll needs raw USB access.
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP"
