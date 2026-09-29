#!/bin/sh
# Build Argyll Profiler.app: compile, bundle ArgyllCMS from Homebrew as self-contained
# helpers, sign (Developer ID + hardened runtime when available, ad-hoc otherwise).
#
#   Scripts/make-app.sh              build + sign  -> .build/Argyll Profiler.app
#   Scripts/make-app.sh --install    also copy to /Applications
#
# Env: CONFIG=debug|release (default release), BREW=/opt/homebrew, IDENTITY="Developer ID Application: …"
set -e
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BREW="${BREW:-/opt/homebrew}"
TOOLS="targen dispcal dispread colprof dispwin spotread"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"

APP=".build/Argyll Profiler.app"
C="$APP/Contents"

swift build -c "$CONFIG" --product ArgyllApp

rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources" "$C/Helpers" "$C/Frameworks"
cp ".build/$CONFIG/ArgyllApp" "$C/MacOS/ArgyllApp"
cp Resources/Info.plist "$C/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$C/Resources/AppIcon.icns"
[ -f Resources/ARGYLL-LICENSE.txt ] && cp Resources/ARGYLL-LICENSE.txt "$C/Resources/"

# ---- bundle ArgyllCMS -------------------------------------------------------
# Non-system dependency references of a Mach-O: Homebrew paths, @rpath and @loader_path.
deps() { otool -L "$1" | awk 'NR>1 {print $1}' | grep -E "^($BREW|@rpath|@loader_path)" || true; }
# Absolute source file for a dependency reference, searching Homebrew for relative ones.
resolve() {
    case "$1" in
        "$BREW"/*) echo "$1" ;;
        *) n=$(basename "$1"); ls "$BREW/lib/$n" "$BREW"/opt/*/lib/"$n" 2>/dev/null | head -1 ;;
    esac
}

for t in $TOOLS; do
    cp "$BREW/bin/$t" "$C/Helpers/$t"
    chmod u+w "$C/Helpers/$t"
done

# Pull every dylib the tools need, transitively, into Contents/Frameworks.
queue=""
for t in $TOOLS; do queue="$queue $(deps "$C/Helpers/$t")"; done
seen=" "
while [ -n "$(echo $queue)" ]; do
    next=""
    for ref in $queue; do
        name=$(basename "$ref")
        case "$seen" in *" $name "*) continue ;; esac
        seen="$seen$name "
        src=$(resolve "$ref")
        if [ -z "$src" ]; then echo "cannot resolve $ref" >&2; exit 1; fi
        cp "$src" "$C/Frameworks/$name"
        chmod u+w "$C/Frameworks/$name"
        next="$next $(deps "$C/Frameworks/$name")"
    done
    queue="$next"
done

# Point everything at the bundled copies.
for t in $TOOLS; do
    f="$C/Helpers/$t"
    for ref in $(deps "$f"); do
        install_name_tool -change "$ref" "@executable_path/../Frameworks/$(basename "$ref")" "$f"
    done
done
for f in "$C/Frameworks/"*.dylib; do
    install_name_tool -id "@loader_path/$(basename "$f")" "$f"
    for ref in $(deps "$f"); do
        install_name_tool -change "$ref" "@loader_path/$(basename "$ref")" "$f"
    done
done

# ---- sign -------------------------------------------------------------------
if [ -n "$IDENTITY" ]; then
    echo "signing with: $IDENTITY"
    for f in "$C/Frameworks/"*.dylib "$C/Helpers/"*; do
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$f" 2>&1 | grep -v 'replacing existing signature' || true
    done
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP" 2>&1 | grep -v 'replacing existing signature' || true
    codesign --verify --deep --strict "$APP"
else
    echo "no Developer ID certificate found; ad-hoc signing"
    codesign --force --deep --sign - "$APP"
fi

# Smoke test: the bundled tools must run from any directory.
ABS="$PWD/$C"
( cd /tmp && "$ABS/Helpers/dispwin" -? 2>&1 | grep -q '^usage' ) \
    || { echo "bundled dispwin does not run" >&2; exit 1; }

echo "built: $APP"
echo "argyll: $(ls "$C/Helpers" | tr '\n' ' ')"
echo "libs:   $(ls "$C/Frameworks" | tr '\n' ' ')"

if [ "$1" = "--install" ]; then
    rm -rf "/Applications/Argyll Profiler.app"
    ditto "$APP" "/Applications/Argyll Profiler.app"
    echo "installed: /Applications/Argyll Profiler.app"
fi
