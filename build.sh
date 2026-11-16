#!/bin/bash
# Builds Steady.app with swiftc. No Xcode project, no derived data.
#
#   ./build.sh            build build/Steady.app
#   ./build.sh --run      build, quit any running copy, open it
#   ./build.sh --install  build, copy to /Applications, open it
#   ./build.sh --selftest build, run the built-in checks, exit with their result
set -euo pipefail

cd "$(dirname "$0")"

MODE="${1:-}"
APP="build/Steady.app"
BIN="$APP/Contents/MacOS/Steady"
ICON="build/AppIcon.icns"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon: drawn by a small Swift script, cached in build/.
if [ ! -f "$ICON" ] || [ scripts/make-icon.swift -nt "$ICON" ]; then
    echo "Drawing app icon"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    swift scripts/make-icon.swift "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$ICON"
    rm -rf "$ICONSET"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

echo "Compiling"
SOURCES=$(find Sources -name '*.swift' | sort)
# shellcheck disable=SC2086
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
    -framework AppKit -framework SwiftUI -framework AVFoundation -framework AVKit \
    -framework Vision -framework CoreImage -framework CoreMedia -framework CoreVideo \
    -framework Carbon -framework ServiceManagement -framework Charts \
    -o "$BIN" $SOURCES

cp Info.plist "$APP/Contents/Info.plist"

# Signing. Camera permission (TCC) is tied to the code signature, so a stable
# "Apple Development" identity keeps the permission across rebuilds.
IDENTITY_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}' || true)
IDENTITY_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)

if [ -n "$IDENTITY_HASH" ]; then
    /usr/libexec/PlistBuddy -c "Add :SteadySigningIdentity string $IDENTITY_NAME" "$APP/Contents/Info.plist" >/dev/null
    codesign --force --sign "$IDENTITY_HASH" "$APP" >/dev/null 2>&1
    echo "Signed with $IDENTITY_NAME"
else
    /usr/libexec/PlistBuddy -c "Add :SteadySigningIdentity string ad-hoc" "$APP/Contents/Info.plist" >/dev/null
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "WARNING: no Apple Development certificate found. Signed ad-hoc."
    echo "         macOS will ask for camera permission again after every rebuild."
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

case "$MODE" in
    --run)
        pkill -x Steady 2>/dev/null || true
        sleep 0.5
        open "$APP"
        ;;
    --install)
        pkill -x Steady 2>/dev/null || true
        sleep 0.5
        rm -rf /Applications/Steady.app
        cp -R "$APP" /Applications/Steady.app
        open /Applications/Steady.app
        echo "Installed to /Applications/Steady.app"
        ;;
    --selftest)
        set +e
        "$BIN" --selftest
        CODE=$?
        exit $CODE
        ;;
    "")
        ;;
    *)
        echo "Unknown option: $MODE"
        exit 2
        ;;
esac
