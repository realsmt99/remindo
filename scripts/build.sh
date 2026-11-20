#!/bin/bash
# Builds build/Remindo.app (release, ad-hoc signed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "→ Compiling Remindo (release)…"
swift build -c release --product Remindo
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Remindo.app"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Remindo" "$APP/Contents/MacOS/Remindo"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/bin/remindo" "$APP/Contents/Resources/remindo"
chmod 755 "$APP/Contents/MacOS/Remindo" "$APP/Contents/Resources/remindo"

echo "→ Drawing the app icon…"
"$APP/Contents/MacOS/Remindo" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "→ Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "✓ Built $APP"
