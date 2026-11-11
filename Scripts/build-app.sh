#!/bin/bash
# Builds a release binary and assembles build/Trill.app.
# Signs with a "Developer ID Application" identity when one is in the keychain (or $TRILL_SIGN_IDENTITY),
# otherwise ad-hoc.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# With Command Line Tools only, the SwiftUI macro plugin (@State etc.) lives in an installed Xcode.app, if any.
EXTRA=()
PLUGINS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
if [ -d "$PLUGINS" ] && ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
fi

# Record the real SDK version in the binary (SwiftPM writes the deployment target instead).
# macOS only gives an app the current system look (Liquid Glass sidebars and toolbars) when it was linked
# against a recent SDK; the minimum OS stays 13.0.
SDKVER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [ -n "$SDKVER" ]; then
    EXTRA+=(-Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$SDKVER")
fi

swift build -c release ${EXTRA[@]+"${EXTRA[@]}"}
BIN="$(swift build -c release --show-bin-path)/Trill"

APP="$ROOT/build/Trill.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Trill"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundled sound packs.
if [ -d "$ROOT/Resources/Sounds" ]; then
    cp -R "$ROOT/Resources/Sounds" "$APP/Contents/Resources/Sounds"
fi

# Icon (optional: skipped if generation fails).
ICONSET="$ROOT/build/Trill.iconset"
rm -rf "$ICONSET"
if swift "$ROOT/Scripts/make-icon.swift" "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Trill.icns" >/dev/null 2>&1; then
    echo "Icon generated."
else
    echo "Icon generation skipped."
fi
rm -rf "$ICONSET"

IDENTITY="${TRILL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier com.karimbacchus.trill "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - --identifier com.karimbacchus.trill "$APP"
    echo "Signed ad-hoc."
fi
echo "Built $APP"
